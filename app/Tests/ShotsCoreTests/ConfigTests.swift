import Foundation
import Testing
@testable import ShotsCore

struct ConfigTests {
    @Test func firstLoadWritesTheDefaultsWithoutDataDir() throws {
        let root = try tempRoot()
        let path = Paths.join(root, "nested/config.json")
        let config = try Config.load(from: path, home: root)
        #expect(config == Config.defaults(home: root))

        let written = try JSONValue.parse(String(contentsOfFile: path, encoding: .utf8))
        #expect(written["dataDir"] == nil)
        #expect(written["codex"]?["model"] == "gpt-6-luna")
        #expect(written["categoryHints"]?["errors"] == "an error message, crash, stack trace, failing build")
        // Pretty-printed like JSON.stringify(seed, null, 2) + "\n", keys in src/config.ts order.
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasPrefix("{\n  \"inbox\": \"\(root)/Screenshots/_inbox\",\n  \"outputRoot\": "))
        #expect(text.hasSuffix("}\n"))
        // Loading the seed again gives the same config.
        #expect(try Config.load(from: path, home: root) == config)
    }

    @Test func mergesShallowlyAndCliBlocksOneLevelDeeper() throws {
        let root = try tempRoot()
        let config = try Config.defaults(home: root).merging([
            "categories": ["code", "memes"],
            "codex": ["model": "gpt-6-sol"],
            "confidenceCap": ["apple": 0.55],
            "inbox": "~/In",
            "outputRoot": "relative/out/../files/",
        ], home: root)
        #expect(config.categories == ["code", "memes", "misc"]) // misc is always added
        #expect(config.codex == CliBackendConfig(binary: "codex", model: "gpt-6-sol", effort: "low"))
        #expect(config.claudeCode.model == "sonnet")
        #expect(config.confidenceCap["apple"] == 0.55)
        #expect(config.inbox == Paths.join(root, "In"))
        #expect(config.outputRoot == Paths.join(FileManager.default.currentDirectoryPath, "relative/files"))
        #expect(config.categoryHints == Config.defaultCategoryHints)
    }

    static let invalid: [(JSONObject, String)] = [
        (["categories": []], "config: categories must be a non-empty array"),
        (["categories": ["Code"]], "config: categories must be lowercase slugs"),
        (["backends": ["apple", "gemini"]], "config: unknown backend \"gemini\""),
        (["backends": "apple"], "config: backends must be an array"),
        (["escalateBelowConfidence": 1.5], "config: escalateBelowConfidence must be 0-1"),
        (["reviewBelowConfidence": -0.1], "config: reviewBelowConfidence must be 0-1"),
        (["concurrency": 3], "config: concurrency must be 1 or 2"),
        (["timeoutMs": 0], "config: timeoutMs must be positive"),
        (["inbox": "/tmp/same", "outputRoot": "/tmp/same/"], "config: inbox and outputRoot must differ"),
        (["allowCloud": "yes"], "config: allowCloud must be true or false"),
    ]

    @Test(arguments: invalid)
    func rejectsInvalidConfigs(_ user: JSONObject, _ message: String) throws {
        #expect(throws: ConfigError.self) { try Config.defaults(home: "/tmp/x").merging(user, home: "/tmp/x") }
        do {
            _ = try Config.defaults(home: "/tmp/x").merging(user, home: "/tmp/x")
        } catch let error as ConfigError {
            #expect(error.message == message)
        }
    }

    @Test func badFilesSayWhatIsWrong() throws {
        let root = try tempRoot()
        let path = Paths.join(root, "config.json")
        try "{ nope".write(toFile: path, atomically: true, encoding: .utf8)
        #expect { try Config.load(from: path, home: root) } throws: { error in
            (error as? ConfigError)?.message.hasPrefix("config: \(path) is not valid JSON") == true
        }
        try "[1, 2]".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: ConfigError("\(path) must hold a JSON object")) { try Config.load(from: path, home: root) }
    }

    @Test func pathHonorsShotsConfig() {
        #expect(Config.path(environment: ["SHOTS_CONFIG": "/tmp/c.json", "HOME": "/Users/x"]) == "/tmp/c.json")
        #expect(Config.path(environment: ["HOME": "/Users/x"]) == "/Users/x/.config/shots/config.json")
    }

    @Test func jsonKeepsTheViewerContractKeys() throws {
        let config = Config.defaults(home: "/Users/x")
        let json = config.json
        #expect(json["inbox"] == "/Users/x/Screenshots/_inbox")
        #expect(json["backends"] == ["apple", "claude-code", "codex"])
        #expect(json["timeoutMs"] == 30000)
        #expect(json.objectValue?.keys.first == "inbox")
        #expect(json.objectValue?.keys.last == "dataDir")
        #expect(config.databasePath == "/Users/x/.local/share/shots/shots.db")
    }
}
