import Foundation
import ShotsCore

/// Reads a binary-plist xattr (the format Spotlight's com.apple.metadata:* attributes use).
func readPlistXattr(path: String, name: String) -> Any? {
    let size = getxattr(path, name, nil, 0, 0, 0)
    guard size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard getxattr(path, name, &buffer, size, 0, 0) == size else { return nil }
    return try? PropertyListSerialization.propertyList(from: Data(buffer), options: [], format: nil)
}

func writePlistXattr(path: String, name: String, value: Any) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    let rc = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
    if rc != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// macOS writes the screen-capture xattrs the moment the file lands; Spotlight (mdls) only
/// reflects them after indexing, which lags or never happens for excluded folders. So xattrs
/// come first and `mdls` is the fallback.
func screenshotMeta(path: String) async throws -> ScreenshotMeta {
    guard FileManager.default.fileExists(atPath: path) else { throw ShotsError("meta: no such file \(path)") }
    let isCapture = readPlistXattr(path: path, name: "com.apple.metadata:kMDItemIsScreenCapture")
    if let isCapture {
        let captureType = readPlistXattr(path: path, name: "com.apple.metadata:kMDItemScreenCaptureType") as? String
        let flag = (isCapture as? NSNumber)?.boolValue
        return ScreenshotMeta(isScreenCapture: flag, captureType: captureType, source: .xattr)
    }
    return await mdlsMeta(path: path)
}

private func mdlsMeta(path: String) async -> ScreenshotMeta {
    let none = ScreenshotMeta(isScreenCapture: nil, captureType: nil, source: .none)
    guard let output = await runMdls(path: path) else { return none }
    let parts = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    let isCap = parts.first ?? ""
    let type = parts.count > 1 ? parts[1] : ""
    if isCap.isEmpty && type.isEmpty { return none }
    return ScreenshotMeta(isScreenCapture: isCap == "1", captureType: type.isEmpty ? nil : type, source: .mdls)
}

/// stdout of `mdls`, or nil on failure or after 5 seconds.
private func runMdls(path: String) async -> String? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
            process.arguments = ["-raw", "-nullMarker", "", "-name", "kMDItemIsScreenCapture", "-name", "kMDItemScreenCaptureType", path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return continuation.resume(returning: nil) }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
        }
    }
}

private func tagName(_ entry: String) -> String {
    entry.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? entry
}

/// Merges tags into com.apple.metadata:_kMDItemUserTags. Each entry is "name\n<color>"; 0 = no color.
/// `remove` drops tags shots applied earlier (recat) while keeping the user's own.
func mergeFinderTags(path: String, tags: [String], remove: [String]) throws {
    let attribute = "com.apple.metadata:_kMDItemUserTags"
    let removeSet = Set(remove)
    let existing = ((readPlistXattr(path: path, name: attribute) as? [String]) ?? []).filter { !removeSet.contains(tagName($0)) }
    var seen = Set(existing.map(tagName))
    var merged = existing
    for tag in tags where !tag.isEmpty && !seen.contains(tag) {
        merged.append("\(tag)\n0")
        seen.insert(tag)
    }
    try writePlistXattr(path: path, name: attribute, value: merged)
}
