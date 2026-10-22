import Foundation

/// Path helpers with Node's `path` semantics, which the TypeScript daemon used. Plain string
/// work: `URL` and `NSString` each normalize a little differently (`/private` prefixes,
/// trailing slashes), and paths stored in the index must compare equal across both daemons.
public enum Paths {
    /// `$HOME`, like Node's `os.homedir()`, falling back to the account's home folder.
    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// `path.join`: joins with `/` and normalizes.
    public static func join(_ parts: String...) -> String { join(parts) }

    public static func join(_ parts: [String]) -> String {
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "/")
        return joined.isEmpty ? "." : normalize(joined)
    }

    /// `path.resolve`: an absolute, normalized path without a trailing slash.
    public static func resolve(_ path: String, cwd: String = FileManager.default.currentDirectoryPath) -> String {
        normalize(path.hasPrefix("/") ? path : cwd + "/" + path, dropTrailingSlash: true)
    }

    /// `~` and `~/…` become the home folder; anything else is returned as is.
    public static func expandHome(_ path: String, home: String = Paths.home()) -> String {
        path == "~" || path.hasPrefix("~/") ? join(home, String(path.dropFirst())) : path
    }

    /// `path.basename`.
    public static func basename(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    /// `path.dirname`.
    public static func dirname(_ path: String) -> String {
        let resolved = normalize(path, dropTrailingSlash: true)
        guard let slash = resolved.lastIndex(of: "/") else { return "." }
        return slash == resolved.startIndex ? "/" : String(resolved[..<slash])
    }

    /// `path.extname`: `.png` for `a.png`, empty for `.bashrc` or `a`.
    public static func extname(_ path: String) -> String {
        let name = basename(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[dot...])
    }

    /// Collapses `//`, `.` and `..`, keeping a trailing slash unless asked not to.
    static func normalize(_ path: String, dropTrailingSlash: Bool = false) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                if let last = parts.last, last != ".." { parts.removeLast() }
                else if !absolute { parts.append(part) }
            default: parts.append(part)
            }
        }
        var result = (absolute ? "/" : "") + parts.joined(separator: "/")
        if result.isEmpty { result = "." }
        if !dropTrailingSlash, path.hasSuffix("/"), !result.hasSuffix("/") { result += "/" }
        return result
    }
}
