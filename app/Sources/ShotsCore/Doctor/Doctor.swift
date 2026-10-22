import Foundation

/// `shots doctor`, ported from src/doctor.ts. Checks the OS, models, CLIs, permissions,
/// screencapture settings, login item and the index.
public enum Doctor {
    public struct Check: Sendable, Equatable {
        public var label: String
        /// true = pass, false = fail, nil = informational.
        public var ok: Bool?
        public var detail: String

        public init(label: String, ok: Bool?, detail: String) {
            self.label = label
            self.ok = ok
            self.detail = detail
        }
    }

    /// Whether Shots.app starts at login. Supplied by the caller because
    /// SMAppService lives outside ShotsCore.
    public struct LoginItem: Sendable {
        public var ok: Bool?
        public var detail: String
        public init(ok: Bool?, detail: String) {
            self.ok = ok
            self.detail = detail
        }
    }

    public struct Report: Sendable {
        public var checks: [Check]
        public var ok: Bool { checks.allSatisfy { $0.ok != false } }
    }

    public static func run(config: Config, native: any Native, loginItem: LoginItem) async -> Report {
        var checks: [Check] = []
        func add(_ label: String, _ ok: Bool?, _ detail: String) {
            checks.append(Check(label: label, ok: ok, detail: detail))
        }

        let sw = await Exec.run("/usr/bin/sw_vers", ["-productVersion"])
        add("macOS", true, sw.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        do {
            let fm = try await native.fmStatus()
            add(
                "Apple Intelligence model", fm.available,
                fm.available
                    ? "available (context \(fm.contextSize.map(String.init) ?? "unknown") tokens)"
                    : "unavailable: \(fm.reason ?? "unknown")"
            )
            add("Apple image input", fm.imageInput.enabled ? true : nil, fm.imageInput.enabled ? "enabled" : "text-only: \(fm.imageInput.reason)")
        } catch {
            add("Apple Intelligence model", false, errorMessage(error))
        }
        do {
            let p = try await native.permissions()
            add("Accessibility (this process)", p.accessibility ? true : nil, p.accessibility ? "granted" : "not granted; the app's own grant is below")
            add("Screen Recording", p.screenRecording ? true : nil, p.screenRecording ? "granted (window titles without AX)" : "not granted (optional)")
            for (app, state) in p.automation.sorted(by: { $0.key < $1.key }) {
                add("Automation → \(app)", state == "granted" ? true : nil, state)
            }
        } catch {
            add("permissions", false, errorMessage(error))
        }

        if let status = DaemonStatus.read(dataDir: config.dataDir) {
            let perms = status["permissions"]?.objectValue
            let accessibility = perms?["accessibility"]?.boolValue
            func show(_ value: JSONValue?) -> String {
                guard let value, !value.isNull else { return "unknown" }
                return value.serialized()
            }
            add(
                "daemon permissions", accessibility,
                "as seen by the app at \(status["updatedAt"]?.stringValue ?? "?"): accessibility=\(show(perms?["accessibility"])), screenRecording=\(show(perms?["screenRecording"])), binary=\(status["execPath"]?.stringValue ?? "?")"
            )
        } else {
            add("daemon permissions", nil, "the app has not run yet (no daemon-status.json)")
        }

        if config.allowCloud {
            if config.backends.contains(.claudeCode) {
                checks += await cliCheck("claude", config.claudeCode.binary, ["--version"], ["auth", "status"]) { out, _ in
                    guard let start = out.firstIndex(of: "{"), let end = out.lastIndex(of: "}"), start < end,
                        let status = try? JSONValue.parse(String(out[start...end]))
                    else { return (false, "could not parse `claude auth status`") }
                    if status["loggedIn"]?.boolValue == true {
                        let method = status["authMethod"]?.stringValue ?? "unknown"
                        let provider = status["apiProvider"]?.stringValue ?? "unknown"
                        return (true, "logged in via \(method) (\(provider)), model \(config.claudeCode.model)")
                    }
                    return (false, "not logged in (run `claude auth login`)")
                }
            }
            if config.backends.contains(.codex) {
                checks += await cliCheck("codex", config.codex.binary, ["--version"], ["login", "status"]) { out, code in
                    let line = out.split(separator: "\n", omittingEmptySubsequences: false).first { $0.localizedCaseInsensitiveContains("logged in") }
                    if code == 0, let line {
                        return (true, "\(line.trimmingCharacters(in: .whitespaces)), model \(config.codex.model)")
                    }
                    return (false, "not logged in (run `codex login`)")
                }
            }
        } else {
            add("cloud backends", nil, "disabled (allowCloud=false)")
        }

        add(
            "config backends", !config.backends.isEmpty,
            config.backends.map(\.rawValue).joined(separator: " → ")
                + " (escalate < \(JSONValue.formatNumber(config.escalateBelowConfidence)), review < \(JSONValue.formatNumber(config.reviewBelowConfidence)))"
        )
        add("inbox", FileManager.default.fileExists(atPath: config.inbox), config.inbox)

        let loc = await Exec.run("/usr/bin/defaults", ["read", "com.apple.screencapture", "location"])
        let location = loc.code == 0 ? Paths.resolve(Paths.expandHome(loc.stdout.trimmingCharacters(in: .whitespacesAndNewlines))) : nil
        add(
            "screencapture location", location == Paths.resolve(config.inbox),
            location ?? "unset (default Desktop); run: defaults write com.apple.screencapture location \"\(config.inbox)\""
        )
        let thumb = await Exec.run("/usr/bin/defaults", ["read", "com.apple.screencapture", "show-thumbnail"])
        let thumbOff = thumb.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
        add(
            "floating thumbnail off", thumbOff ? true : nil,
            thumbOff ? "off" : "on: files land ~5s late, so app context may describe the wrong app (defaults write com.apple.screencapture show-thumbnail -bool false)"
        )

        add("Shots.app login item", loginItem.ok, loginItem.detail)

        do {
            let database = try Database(path: config.databasePath)
            let s = try await database.stats()
            let jobs = JSONValue.object(JSONObject(s.jobs.sorted { $0.key < $1.key }.map { ($0.key, JSONValue($0.value)) })).serialized()
            let byBackend = s.byBackend.map { "\($0.backend)=\($0.count)" }.joined(separator: " ")
            add("index", true, "\(s.shots) shots, \(s.review) for review, jobs \(jobs), by backend \(byBackend.isEmpty ? "-" : byBackend)")
            await database.close()
        } catch {
            add("index", false, errorMessage(error))
        }
        return Report(checks: checks)
    }

    /// One mark per check: ✓ pass, ✗ fail, • informational.
    public static func format(_ checks: [Check]) -> String {
        let width = checks.map(\.label.count).max() ?? 0
        return checks.map { check in
            let mark = check.ok == true ? "✓" : check.ok == false ? "✗" : "•"
            return "\(mark) \(check.label.padding(toLength: max(width, check.label.count), withPad: " ", startingAt: 0))  \(check.detail)"
        }.joined(separator: "\n")
    }

    private static func cliCheck(
        _ name: String, _ binary: String, _ versionArgs: [String], _ authArgs: [String],
        parseAuth: (_ output: String, _ code: Int32?) -> (ok: Bool, detail: String)
    ) async -> [Check] {
        // The PATH the backends themselves use, so doctor finds what the pipeline will run.
        let env = Exec.augmentedEnvironment()
        guard let path = Exec.which(binary, path: env["PATH"] ?? "") else {
            return [Check(label: "\(name) CLI", ok: false, detail: "\(binary) not on PATH")]
        }
        async let version = Exec.run(path, versionArgs, timeout: .seconds(15), environment: env)
        async let auth = Exec.run(path, authArgs, timeout: .seconds(15), environment: env)
        let (ver, authResult) = await (version, auth)
        let firstLine = ver.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parsed = parseAuth("\(authResult.stdout)\n\(authResult.stderr)".trimmingCharacters(in: .whitespacesAndNewlines), authResult.code)
        return [
            Check(label: "\(name) CLI", ok: ver.code == 0, detail: "\(firstLine) (\(path))"),
            Check(label: "\(name) auth", ok: parsed.ok, detail: parsed.detail),
        ]
    }
}
