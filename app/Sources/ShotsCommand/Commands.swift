import Foundation
import ShotsCore
import ShotsNative

/// One function per command. Each returns the exit status; errors propagate to main.swift,
/// which prints them (`error: …`, or the usage text for a `UsageError`).
enum Commands {
    /// `shots run`: the daemon in the foreground. Writes daemon-status.json, starts the
    /// `Daemon`, and stops it cleanly (at most 10 s) on SIGTERM/SIGINT.
    static func run(config: Config) async throws -> Int32 {
        let deps = try makeDeps(config)
        async let permissions = statusField { try await deps.native.permissions().json }
        async let fm = statusField { try await deps.native.fmStatus().json }
        let (permissionsJSON, fmJSON) = await (permissions, fm)
        let execPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        try DaemonStatus.write(dataDir: config.dataDir, fields: [
            "pid": JSONValue(Int(ProcessInfo.processInfo.processIdentifier)),
            "execPath": .string(execPath),
            "permissions": permissionsJSON,
            "fm": fmJSON,
        ])
        deps.log.info("starting", ["config": .string(Config.path()), "permissions": permissionsJSON, "fm": fmJSON])

        let daemon = Daemon(deps: deps)
        try await daemon.start()

        let signal = await waitForTerminationSignal()
        deps.log.info("stopping", ["signal": .string(signal), "queued": JSONValue(await daemon.queue.size)])
        // Running jobs get 10 s to finish; queued ones stay pending for the next start.
        _ = await withDeadline(.seconds(10)) { await daemon.stop() }
        await deps.database.close()
        return 0
    }

    /// `shots search <query> [--limit N] [--json]`. `--json` prints the rows without
    /// `ocr_text` but with `snippet`, pretty-printed.
    static func search(_ args: [String], config: Config) async throws -> Int32 {
        let parsed = try Arguments(args, options: ["limit"], booleans: ["json"])
        let query = parsed.positionals.joined(separator: " ")
        if query.isEmpty { throw UsageError("search needs a query") }
        guard let limit = Int(parsed["limit"] ?? "20"), limit > 0 else { throw UsageError("--limit must be a positive number") }

        let database = try Database(path: config.databasePath)
        let hits = try await database.search(query, limit: limit)
        await database.close()

        if parsed.has("json") {
            let rows: [JSONValue] = hits.map { hit in
                var row = hit.shot.jsonObject
                row["ocr_text"] = nil
                row["snippet"] = .string(hit.snippet)
                return .object(row)
            }
            print(JSONValue.array(rows).serialized(indent: 2))
        } else if hits.isEmpty {
            print("no matches")
        } else {
            for hit in hits {
                let shot = hit.shot
                print("\(shot.capturedAt.prefix(16).replacingOccurrences(of: "T", with: " "))  [\(shot.category)]  \(shot.title)")
                print("    \(short(shot.path))")
                let meta = [shot.appName, shot.url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty { print("    \(meta)") }
                let snippet = hit.snippet.replacing(/\s+/, with: " ")
                if !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { print("    \(snippet.prefix(160))") }
            }
        }
        return 0
    }

    /// `shots recat <file> [--backend b] [--category c] [--json]`. `--json` prints
    /// `RecatOutput.json` on one line: the viewer's contract.
    static func recat(_ args: [String], config: Config) async throws -> Int32 {
        let parsed = try Arguments(args, options: ["backend", "category"], booleans: ["json"])
        guard let ref = parsed.positionals.first else { throw UsageError("recat needs a file") }
        let deps = try makeDeps(config)
        guard let shot = try await deps.database.findShot(ref, resolvedPath: Paths.resolve(ref)) else {
            throw UsageError("not in the index: \(ref)")
        }
        var options = RecatOptions(category: parsed["category"])
        if let name = parsed["backend"] {
            guard let backend = BackendName(rawValue: name) else { throw UsageError("unknown backend \"\(name)\"") }
            options.backends = [createBackend(backend, config: config, native: deps.native)]
        }
        let output = try await ShotsCore.recat(shot, options: options, deps: deps)
        if parsed.has("json") {
            // Contract for the Shots.app viewer: { shot, decision }.
            print(output.json.serialized())
            return 0
        }
        let (updated, decision) = (output.shot, output.decision)
        print("\(short(shot.path))\n  → \(short(updated.path))")
        let review = decision.review ? ", review (suggested: \(decision.suggestedCategory ?? "none"))" : ""
        print("  \(decision.final.category) (\(String(format: "%.2f", decision.final.confidence)) via \(decision.backend))\(review)")
        for attempt in decision.attempts {
            let outcome: String
            switch attempt.outcome {
            case .success(let result, _): outcome = "ok \(result.category) \(JSONValue.formatNumber(result.confidence))"
            case .failure(let kind, let message): outcome = "\(kind.rawValue): \(message)"
            }
            print("  \(attempt.backend): \(outcome) (\(attempt.ms)ms)")
        }
        return 0
    }

    /// `shots review [--failed]`.
    static func review(_ args: [String], config: Config) async throws -> Int32 {
        let parsed = try Arguments(args, booleans: ["failed"])
        let database = try Database(path: config.databasePath)
        defer { Task { await database.close() } }

        if parsed.has("failed") {
            let jobs = try await database.failedJobs()
            if jobs.isEmpty { print("no failed jobs") }
            for job in jobs {
                print("\(job.updatedAt.prefix(16))  attempts=\(job.attempts)  \(short(job.inboxPath))\n    \(job.lastError ?? "")")
            }
            return 0
        }
        let rows = try await database.reviewQueue()
        if rows.isEmpty { print("nothing to review") }
        for row in rows {
            print("\(row.capturedAt.prefix(16).replacingOccurrences(of: "T", with: " "))  suggested=\(row.suggestedCategory ?? "-")  conf=\(String(format: "%.2f", row.confidence))  via \(row.backend)")
            print("    \(short(row.path))  \"\(row.title)\"")
        }
        if !rows.isEmpty {
            print("\nfix with: shots recat <file> --category <name>   or   shots recat <file> --backend claude-code")
        }
        return 0
    }

    /// `shots cleanup [--scan] [--delete] [--json]` and `shots cleanup --keep <file>`.
    /// Lists scratch shots older than `cleanupAfterHours`. `--scan` first runs the classifier
    /// chain on shots filed before it judged scratch (one chain run each).
    static func cleanup(_ args: [String], config: Config) async throws -> Int32 {
        let parsed = try Arguments(args, options: ["keep"], booleans: ["scan", "delete", "json"])
        let deps = try makeDeps(config)
        let database = deps.database
        defer { Task { await database.close() } }

        if let ref = parsed["keep"] {
            guard let shot = try await database.findShot(ref, resolvedPath: Paths.resolve(ref)) else {
                throw UsageError("not in the index: \(ref)")
            }
            try await database.keep(shot.id)
            print("kept \(short(shot.path))")
            return 0
        }

        if parsed.has("scan") {
            let unjudged = try await database.unjudgedShots()
            for (index, shot) in unjudged.enumerated() {
                let verdict: String
                do {
                    verdict = try await judgeScratch(shot, deps: deps) ? "scratch" : "keep"
                } catch {
                    verdict = "error: \(errorMessage(error))"
                }
                writeError("[\(index + 1)/\(unjudged.count)] \(verdict)  \(short(shot.path))\n")
            }
        }

        let rows = try await database.cleanupSuggestions(capturedBefore: config.cleanupCutoff())
        if parsed.has("delete") {
            for row in rows {
                _ = try await softDelete(row, deps: deps)
                print("deleted \(short(row.path))")
            }
            if rows.isEmpty { print("nothing to clean up") }
        } else if parsed.has("json") {
            print(JSONValue.array(rows.map { row in
                var object = row.jsonObject
                object["ocr_text"] = nil
                return .object(object)
            }).serialized(indent: 2))
        } else if rows.isEmpty {
            print("nothing to clean up")
        } else {
            for row in rows {
                print("\(row.capturedAt.prefix(16).replacingOccurrences(of: "T", with: " "))  [\(row.category)]  \(row.title)")
                print("    \(short(row.path))")
            }
            print("\nmove them to Recently Deleted with: shots cleanup --delete   keep one with: shots cleanup --keep <file>")
        }
        return 0
    }

    /// `shots doctor`: exit 1 when any check fails.
    static func doctor(config: Config) async throws -> Int32 {
        let report = await Doctor.run(config: config, native: SystemNative(), loginItem: loginItemStatus())
        print(Doctor.format(report.checks))
        return report.ok ? 0 : 1
    }

    /// `shots config [--json]`. `--json` prints `{path, dbPath, config}` on one line: the
    /// viewer's contract.
    static func config(_ args: [String], config: Config) -> Int32 {
        if args.contains("--json") {
            let output: JSONValue = ["path": .string(Config.path()), "dbPath": .string(config.databasePath), "config": config.json]
            print(output.serialized())
        } else {
            print("# \(Config.path())")
            print(config.json.serialized(indent: 2))
        }
        return 0
    }

    // MARK: Shared

    /// The live dependencies: SystemNative, the configured backends, the index.
    static func makeDeps(_ config: Config) throws -> Deps {
        Deps(config: config, database: try Database(path: config.databasePath), native: SystemNative())
    }

    /// SMAppService only describes the app when this executable sits in Shots.app/Contents/Helpers.
    static func loginItemStatus() -> Doctor.LoginItem {
        // Usually invoked through the ~/.local/bin/shots symlink, so resolve it first.
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        guard let range = executable.range(of: ".app/Contents/Helpers/") else {
            return Doctor.LoginItem(ok: false, detail: "Shots.app is not installed (this shots is not running from inside the bundle)")
        }
        let bundleURL = URL(fileURLWithPath: String(executable[..<range.lowerBound]) + ".app")
        guard let bundle = Bundle(url: bundleURL), bundle.bundleIdentifier != nil else {
            return Doctor.LoginItem(ok: false, detail: "could not read the Shots.app bundle at \(bundleURL.path)")
        }
        // mainApp refers to the *calling* app, so from the helper we can only report that the
        // bundle exists; the app's own login-item state is shown in its Settings.
        return Doctor.LoginItem(ok: nil, detail: "Shots.app at \(short(bundleURL.path)); toggle \"Launch at Login\" in its menu or Status window")
    }

    /// Wraps a native check so a failure becomes `{error}` in daemon-status.json.
    private static func statusField(_ body: () async throws -> JSONValue) async -> JSONValue {
        do { return try await body() } catch { return ["error": .string(errorMessage(error))] }
    }

    /// Suspends until SIGTERM or SIGINT arrives; returns its name.
    private static func waitForTerminationSignal() async -> String {
        await withCheckedContinuation { continuation in
            let sources = SignalBox()
            for (number, name) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    if sources.claim() { continuation.resume(returning: name) }
                }
                source.resume()
                sources.keep(source)
            }
        }
    }

    /// `~` for the home folder in paths shown to people.
    static func short(_ path: String) -> String {
        let home = Paths.home()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Keeps the signal sources alive and makes sure only the first signal resumes the continuation.
private final class SignalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var claimed = false

    func keep(_ source: DispatchSourceSignal) { lock.withLock { sources.append(source) } }
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
