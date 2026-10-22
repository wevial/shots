import Foundation

/// A failed `shots` command. `message` is what the CLI printed, ready to show in an alert.
public struct ShotsCLIError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The write side of the app. Every change goes through the `shots` command, which owns the
/// moving, renaming, Finder tags and database updates. The app never writes SQLite itself.
public struct ShotsCLI: Sendable {
    public var executable: URL
    /// Environment for the child process; nil inherits the app's.
    public var environment: [String: String]?

    public init(executable: URL, environment: [String: String]? = nil) {
        self.executable = executable
        self.environment = environment
    }

    /// `$SHOTS_BIN`, then `~/.local/bin/shots`, then `~/.local/share/shots/bin/shots`.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> ShotsCLI? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [environment["SHOTS_BIN"], "\(home)/.local/bin/shots", "\(home)/.local/share/shots/bin/shots"]
        guard let path = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return ShotsCLI(executable: URL(filePath: path), environment: childEnvironment(base: environment))
    }

    // MARK: Commands

    public func config() async throws -> ShotsConfig {
        try await decode(ShotsConfig.self, from: run(["config", "--json"]))
    }

    /// Files the shot under `category` by hand. The file moves, so use the returned shot's path.
    public func recategorize(path: String, to category: String) async throws -> RecatResult {
        try await decode(RecatResult.self, from: run(["recat", path, "--category", category, "--json"]))
    }

    /// Classifies the shot again with one backend. Cloud backends take 5–30 seconds.
    public func rerun(path: String, backend: ClassifierBackend) async throws -> RecatResult {
        try await decode(RecatResult.self, from: run(["recat", path, "--backend", backend.rawValue, "--json"]))
    }

    // MARK: Plumbing

    func run(_ arguments: [String]) async throws -> Data {
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(executable, arguments: arguments, environment: environment)
        } catch {
            throw ShotsCLIError(message: "Couldn't run \(executable.path): \(error.localizedDescription)")
        }
        guard output.status == 0 else {
            throw ShotsCLIError(message: Self.errorMessage(stderr: output.stderrText, status: output.status))
        }
        return output.stdout
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ShotsCLIError(message: "Unexpected output from shots: \(error.localizedDescription)")
        }
    }

    /// The CLI prints `error: <message>` (or a usage error followed by the help text).
    static func errorMessage(stderr: String, status: Int32) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.hasPrefix("error:") }) {
            return String(line.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.first(where: { !$0.isEmpty }) ?? "shots exited with status \(status)"
    }

    /// Apps launched from Finder get a bare PATH, but `recat --backend claude-code` has to find
    /// `claude` and `codex`. Reuse the PATH that install.sh baked into the LaunchAgent, which is
    /// the one the daemon already classifies with.
    static func childEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let agentPlist = URL(filePath: "\(home)/Library/LaunchAgents/com.shots.agent.plist")
        if let data = try? Data(contentsOf: agentPlist),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let variables = plist["EnvironmentVariables"] as? [String: String],
           let path = variables["PATH"] {
            environment["PATH"] = path
        } else {
            let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
            environment["PATH"] = (extra + [base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        }
        return environment
    }
}
