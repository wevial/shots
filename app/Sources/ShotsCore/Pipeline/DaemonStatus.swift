import Foundation

/// `<dataDir>/daemon-status.json`: what the running daemon saw at startup (its binary,
/// permissions and model status). `shots doctor` reads it, because TCC grants belong to
/// the daemon's process, not to the terminal running doctor.
public enum DaemonStatus {
    /// Writes `fields` plus `updatedAt`, pretty-printed like the old daemon did.
    /// Typical fields: `pid`, `execPath`, `permissions` (or `{error}`), `fm` (or `{error}`).
    public static func write(dataDir: String, fields: JSONObject) throws {
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        var status = fields
        status["updatedAt"] = .string(Timestamp.now())
        try JSONValue.object(status).serialized(indent: 2).write(toFile: Paths.join(dataDir, "daemon-status.json"), atomically: true, encoding: .utf8)
    }

    /// The usual fields for a daemon that just started: `pid`, `execPath`, and what this
    /// process sees of `permissions` and `fm` (each `{error}` when the check itself failed).
    public static func startupFields(native: any Native, execPath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) async -> JSONObject {
        func capture(_ check: () async throws -> JSONValue) async -> JSONValue {
            do { return try await check() } catch { return ["error": .string(errorMessage(error))] }
        }
        return [
            "pid": JSONValue(Int(ProcessInfo.processInfo.processIdentifier)),
            "execPath": .string(execPath),
            "permissions": await capture { try await native.permissions().json },
            "fm": await capture { try await native.fmStatus().json },
        ]
    }

    /// The last status written, or nil when the daemon hasn't run (or the file is unreadable).
    public static func read(dataDir: String) -> JSONObject? {
        guard let text = try? String(contentsOfFile: Paths.join(dataDir, "daemon-status.json"), encoding: .utf8) else { return nil }
        return (try? JSONValue.parse(text))?.objectValue
    }
}
