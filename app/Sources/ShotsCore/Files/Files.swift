import CryptoKit
import Foundation

/// File handling for the inbox and the filed screenshots: what counts as a candidate,
/// waiting for a write to finish, hashing, naming and moving. Ported from src/files.ts.
public enum Files {
    public static let imageExtensions: Set<String> = [".png", ".jpg", ".jpeg", ".heic", ".tiff", ".tif", ".gif", ".bmp", ".webp"]

    /// macOS writes screenshots as hidden ".Screenshot …" temp files first, then renames them.
    public static func isCandidate(_ path: String) -> Bool {
        let name = Paths.basename(path)
        return !name.hasPrefix(".") && imageExtensions.contains(Paths.extname(name).lowercased())
    }

    // MARK: Waiting for a write to finish

    public struct StableOptions: Sendable, Equatable {
        public var interval: Duration
        public var stableChecks: Int
        public var timeout: Duration

        public init(interval: Duration = .milliseconds(250), stableChecks: Int = 2, timeout: Duration = .seconds(30)) {
            self.interval = interval
            self.stableChecks = stableChecks
            self.timeout = timeout
        }
    }

    public struct FileInfo: Sendable, Equatable {
        public var size: Int64
        /// Modification time in nanoseconds since 1970.
        public var modifiedNanos: Int64
        /// Creation time, if the file system records one.
        public var created: Date?
        public var modified: Date
    }

    /// `stat` for one path. Throws `ENOENT` and friends as `POSIXError`.
    public static func info(_ path: String) throws -> FileInfo {
        var s = stat()
        guard stat(path, &s) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        func nanos(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec) }
        func date(_ t: timespec) -> Date { Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9) }
        let birth = nanos(s.st_birthtimespec)
        return FileInfo(
            size: Int64(s.st_size),
            modifiedNanos: nanos(s.st_mtimespec),
            created: birth > 0 ? date(s.st_birthtimespec) : nil,
            modified: date(s.st_mtimespec)
        )
    }

    /// Returns once size and modification time hold still for `stableChecks` polls in a row.
    /// A missing file counts as not stable yet (it may be mid-rename).
    @discardableResult
    public static func waitForStable(_ path: String, options: StableOptions = StableOptions()) async throws -> FileInfo {
        let clock = ContinuousClock()
        let deadline = clock.now + options.timeout
        var last = ""
        var stable = 0
        while clock.now < deadline {
            let signature: String
            do {
                let current = try info(path)
                signature = "\(current.size):\(current.modifiedNanos)"
                if current.size > 0, signature == last {
                    stable += 1
                    if stable >= options.stableChecks { return current }
                } else {
                    stable = 0
                }
            } catch let error as POSIXError where error.code == .ENOENT {
                signature = "missing"
                stable = 0
            }
            last = signature
            try await Task.sleep(for: options.interval)
        }
        throw ShotsError("file never stabilised within \(options.timeout.milliseconds)ms")
    }

    // MARK: Content

    /// Lowercase hex SHA-256 of the file's bytes, read in chunks.
    public static func sha256(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ShotsError("cannot read \(path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Screenshot creation time: birthtime survives the hidden-temp-file rename macOS does.
    public static func capturedAt(_ path: String) throws -> Date {
        let current = try info(path)
        return current.created ?? current.modified
    }

    // MARK: Naming

    /// Local time, `YYYY-MM-DD_HHMM`.
    public static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func pad(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        return "\(c.year ?? 0)-\(pad(c.month))-\(pad(c.day))_\(pad(c.hour))\(pad(c.minute))"
    }

    /// Lowercase, hyphenated, accents stripped, at most 60 characters; never empty.
    public static func slugTitle(_ title: String) -> String {
        // Unicode-scalar semantics throughout, as in JavaScript: after NFKD a letter and its
        // accent are separate scalars, and the accent is what gets dropped.
        let decomposed = title.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }
        var slug = String(String.UnicodeScalarView(decomposed)).lowercased()
        slug = slug.replacing(/[^\p{L}\p{N}]+/.matchingSemantics(.unicodeScalar), with: "-")
        slug = slug.replacing(/^-+|-+$/.matchingSemantics(.unicodeScalar), with: "")
        slug = String(String.UnicodeScalarView(slug.unicodeScalars.prefix(60)))
        slug = slug.replacing(/-+$/.matchingSemantics(.unicodeScalar), with: "")
        return slug.isEmpty ? "screenshot" : slug
    }

    /// `YYYY-MM-DD_HHMM_<slug><ext>`, with the extension lowercased.
    public static func targetName(captured: Date, title: String, ext: String, calendar: Calendar = .current) -> String {
        "\(stamp(captured, calendar: calendar))_\(slugTitle(title))\(ext.lowercased())"
    }

    /// `name` in `dir`, or `name-2`, `name-3`… so existing files are never overwritten.
    /// `exclude` is a path that counts as free (the file's own current path, for recat).
    public static func uniquePath(in dir: String, name: String, excluding exclude: String? = nil) -> String {
        let ext = Paths.extname(name)
        let stem = String(name.dropLast(ext.count))
        var i = 1
        while true {
            let candidate = Paths.join(dir, i == 1 ? name : "\(stem)-\(i)\(ext)")
            if candidate == exclude || !FileManager.default.fileExists(atPath: candidate) { return candidate }
            i += 1
        }
    }

    // MARK: Moving

    /// Moves without ever overwriting and without a moment where the file exists nowhere:
    /// hard-link then unlink on the same volume, copy-verify-unlink across volumes.
    /// Creates the destination folder. Never deletes the source unless the destination exists.
    public static func safeMove(from src: String, to dest: String) throws {
        try FileManager.default.createDirectory(atPath: Paths.dirname(dest), withIntermediateDirectories: true)
        if src == dest { return }
        if link(src, dest) == 0 { // fails with EEXIST instead of clobbering
            try check(unlink(src), "unlink", src)
            return
        }
        let code = errno
        if code == EEXIST { throw ShotsError("destination exists: \(dest)") }
        guard code == EXDEV || code == EPERM || code == ENOTSUP else { throw posixError(code, "link", src, dest) }

        if FileManager.default.fileExists(atPath: dest) { throw ShotsError("destination exists: \(dest)") }
        if rename(src, dest) == 0 { return }
        guard errno == EXDEV else { throw posixError(errno, "rename", src, dest) }
        try FileManager.default.copyItem(atPath: src, toPath: dest)
        guard try info(dest).size == info(src).size else {
            try? FileManager.default.removeItem(atPath: dest)
            throw ShotsError("copy verification failed")
        }
        try check(unlink(src), "unlink", src)
    }

    private static func check(_ result: Int32, _ call: String, _ path: String) throws {
        if result != 0 { throw posixError(errno, call, path) }
    }

    /// Like Node's messages: `No such file or directory, link 'a' -> 'b'`.
    private static func posixError(_ code: Int32, _ call: String, _ src: String, _ dest: String? = nil) -> ShotsError {
        let target = dest.map { " -> '\($0)'" } ?? ""
        return ShotsError("\(String(cString: strerror(code))), \(call) '\(src)'\(target)")
    }
}

extension Duration {
    /// Whole milliseconds, for messages and JSON.
    public var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
