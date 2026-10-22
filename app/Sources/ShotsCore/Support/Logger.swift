import Foundation

/// JSON-lines logging, one object per line: `{"t":…,"level":…,"msg":…, …fields}`.
///
/// By default info and debug go to stdout and warnings and errors to stderr (the CLI).
/// The app logs to ~/Library/Logs/shots/shots.log through `Logger.file(at:)`.
public struct Logger: Sendable {
    public enum Level: String, Sendable, Comparable, CaseIterable {
        case debug, info, warn, error

        public static func < (a: Level, b: Level) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public typealias Sink = @Sendable (_ level: Level, _ line: String) -> Void

    public var minLevel: Level
    private let sink: Sink?

    /// `minLevel` defaults to `$SHOTS_LOG_LEVEL`, else info.
    public init(minLevel: Level? = nil, sink: Sink? = nil) {
        self.minLevel = minLevel
            ?? ProcessInfo.processInfo.environment["SHOTS_LOG_LEVEL"].flatMap(Level.init(rawValue:))
            ?? .info
        self.sink = sink ?? Logger.standardStreams
    }

    /// Drops everything. For tests.
    public static let silent = Logger(minLevel: .error, silent: ())

    private init(minLevel: Level, silent: Void) {
        self.minLevel = minLevel
        self.sink = nil
    }

    public func debug(_ msg: String, _ fields: JSONObject = [:]) { emit(.debug, msg, fields) }
    public func info(_ msg: String, _ fields: JSONObject = [:]) { emit(.info, msg, fields) }
    public func warn(_ msg: String, _ fields: JSONObject = [:]) { emit(.warn, msg, fields) }
    public func error(_ msg: String, _ fields: JSONObject = [:]) { emit(.error, msg, fields) }

    private func emit(_ level: Level, _ msg: String, _ fields: JSONObject) {
        guard let sink, level >= minLevel else { return }
        var line: JSONObject = ["t": .string(Timestamp.now()), "level": .string(level.rawValue), "msg": .string(msg)]
        for (key, value) in fields { line[key] = value }
        sink(level, JSONValue.object(line).serialized())
    }

    private static let standardStreams: Sink = { level, line in
        let handle: FileHandle = level >= .warn ? .standardError : .standardOutput
        handle.write(Data((line + "\n").utf8))
    }

    /// Appends every level to one file, for the app: a GUI app's stdout goes nowhere.
    /// Rolls the file to `<name>.1` when it passes `maxBytes` at startup.
    /// Touches nothing until the first line, so previews and tests that never log stay clean.
    public static func file(at path: String, maxBytes: Int = 10 << 20) -> Sink {
        { _, line in
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: path)[.size] as? Int, size > maxBytes {
                try? fm.removeItem(atPath: path + ".1")
                try? fm.moveItem(atPath: path, toPath: path + ".1")
            }
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            // O_APPEND makes each write(2) of one line land whole, even from concurrent tasks.
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let bytes = Array((line + "\n").utf8)
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        }
    }
}
