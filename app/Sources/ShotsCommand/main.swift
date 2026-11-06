// `shots`: the command-line side of Shots.app. Ships inside the bundle at
// Contents/Helpers/shots. Same commands, flags and output as the TypeScript CLI (src/cli.ts).
import Foundation
import ShotsCore

let usage = """
    shots — auto-organize macOS screenshots

      shots run                         watch the inbox headless (Shots.app normally does this)
      shots search <query> [--limit N]  full-text search over OCR, titles, tags, app, URL
      shots recat <file> [--backend <\(BackendName.allCases.map(\.rawValue).joined(separator: "|"))>] [--category <name>] [--json]
                                        re-classify and re-file an indexed screenshot
      shots review [--failed]           list low-confidence / unknown-category shots (or failed jobs)
      shots cleanup [--scan] [--delete] [--json]
                                        list scratch shots worth deleting; --scan judges older shots
                                        first, --delete moves the list to Recently Deleted
      shots cleanup --keep <file>       never suggest this one again
      shots doctor                      check OS, models, CLIs, auth, permissions, config
      shots config [--json]             print the effective config and its path

    """

func main(_ argv: [String]) async throws -> Int32 {
    guard let command = argv.first, !["help", "--help", "-h"].contains(command) else {
        print(usage, terminator: "")
        return argv.isEmpty ? 1 : 0
    }
    let rest = Array(argv.dropFirst())
    let config = try Config.load()

    switch command {
    case "run": return try await Commands.run(config: config)
    case "search": return try await Commands.search(rest, config: config)
    case "recat": return try await Commands.recat(rest, config: config)
    case "review": return try await Commands.review(rest, config: config)
    case "cleanup": return try await Commands.cleanup(rest, config: config)
    case "doctor": return try await Commands.doctor(config: config)
    case "config": return Commands.config(rest, config: config)
    default: throw UsageError("unknown command \"\(command)\"")
    }
}

func writeError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

do {
    exit(try await main(Array(CommandLine.arguments.dropFirst())))
} catch let error as UsageError {
    writeError("\(error.message)\n\n\(usage)")
    exit(2)
} catch let error as ConfigError {
    writeError("\(error.message)\n")
    exit(1)
} catch {
    writeError("error: \(errorMessage(error))\n")
    exit(1)
}
