import Foundation

/// Reads a binary-plist-encoded xattr (the format Spotlight's com.apple.metadata:* attrs use).
func readPlistXattr(path: String, name: String) -> Any? {
    let size = getxattr(path, name, nil, 0, 0, 0)
    guard size > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard getxattr(path, name, &buf, size, 0, 0) == size else { return nil }
    return try? PropertyListSerialization.propertyList(from: Data(buf), options: [], format: nil)
}

func writePlistXattr(path: String, name: String, value: Any) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    let rc = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
    if rc != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// macOS writes kMDItemIsScreenCapture/kMDItemScreenCaptureType as xattrs the moment the
/// file lands; Spotlight (mdls) only reflects them after indexing, which lags or never
/// happens for excluded folders. So xattrs are the primary source.
func screenshotMetadata(path: String) -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else { fail("meta: no such file \(path)") }
    let isCapture = readPlistXattr(path: path, name: "com.apple.metadata:kMDItemIsScreenCapture")
    let captureType = readPlistXattr(path: path, name: "com.apple.metadata:kMDItemScreenCaptureType")
    let rect = readPlistXattr(path: path, name: "com.apple.metadata:kMDItemScreenCaptureGlobalRect")
    var out: [String: Any] = ["source": isCapture == nil ? "none" : "xattr"]
    if let b = isCapture as? Bool { out["isScreenCapture"] = b }
    else if let n = isCapture as? NSNumber { out["isScreenCapture"] = n.boolValue }
    if let t = captureType as? String { out["captureType"] = t }
    if let r = rect as? [NSNumber] { out["globalRect"] = r.map { $0.doubleValue } }
    return out
}

private func tagName(_ entry: String) -> String {
    entry.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? entry
}

/// Merges tags into com.apple.metadata:_kMDItemUserTags. Each entry is "name\n<color>"; 0 = no color.
/// `remove` drops tags this tool applied earlier (recat) while keeping the user's own.
func setFinderTags(path: String, tags: [String], remove: [String] = []) throws -> [String: Any] {
    let name = "com.apple.metadata:_kMDItemUserTags"
    let removeSet = Set(remove)
    let existing = ((readPlistXattr(path: path, name: name) as? [String]) ?? []).filter { !removeSet.contains(tagName($0)) }
    var seen = Set(existing.map(tagName))
    var merged = existing
    for tag in tags where !tag.isEmpty && !seen.contains(tag) {
        merged.append("\(tag)\n0")
        seen.insert(tag)
    }
    try writePlistXattr(path: path, name: name, value: merged)
    return ["tags": merged.map(tagName)]
}
