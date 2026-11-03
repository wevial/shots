import Foundation
import ShotsCore

/// The parts of `shots config --json` the viewer needs.
public struct ShotsConfig: Sendable, Equatable {
    /// Where the config file lives (`~/.config/shots/config.json`).
    public var configPath: String
    public var dbPath: String
    public var categories: [String]
    public var categoryHints: [String: String]
    public var outputRoot: String
    public var inbox: String
    /// Scratch shots show up in Clean Up once they're this old.
    public var cleanupAfterHours: Int

    public init(
        configPath: String,
        dbPath: String,
        categories: [String],
        categoryHints: [String: String] = [:],
        outputRoot: String,
        inbox: String,
        cleanupAfterHours: Int = 24
    ) {
        self.configPath = configPath
        self.dbPath = dbPath
        self.categories = categories
        self.categoryHints = categoryHints
        self.outputRoot = outputRoot
        self.inbox = inbox
        self.cleanupAfterHours = cleanupAfterHours
    }

    /// What the daemon uses when no config file overrides it.
    public static var defaults: ShotsConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var config = ShotsConfig(Config.defaults(home: home), configPath: "\(home)/.config/shots/config.json")
        config.categoryHints = [:]
        return config
    }

    /// The viewer's slice of a loaded config, for running without the CLI.
    public init(_ config: Config, configPath: String = Config.path()) {
        self.init(
            configPath: configPath,
            dbPath: config.databasePath,
            categories: config.categories,
            categoryHints: config.categoryHints,
            outputRoot: config.outputRoot,
            inbox: config.inbox,
            cleanupAfterHours: config.cleanupAfterHours
        )
    }

    public var inboxURL: URL { URL(filePath: inbox) }

    /// Scratch shots captured before this show up in Clean Up.
    public func cleanupCutoff(now: Date = .now) -> Date { now.addingTimeInterval(-Double(cleanupAfterHours) * 3600) }
}

extension ShotsConfig: Decodable {
    private enum CodingKeys: String, CodingKey { case path, dbPath, config }
    private enum ConfigKeys: String, CodingKey { case categories, categoryHints, outputRoot, inbox, cleanupAfterHours }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let config = try c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config)
        self.init(
            configPath: try c.decode(String.self, forKey: .path),
            dbPath: try c.decode(String.self, forKey: .dbPath),
            categories: try config.decode([String].self, forKey: .categories),
            categoryHints: try config.decodeIfPresent([String: String].self, forKey: .categoryHints) ?? [:],
            outputRoot: try config.decode(String.self, forKey: .outputRoot),
            inbox: try config.decode(String.self, forKey: .inbox),
            cleanupAfterHours: try config.decodeIfPresent(Int.self, forKey: .cleanupAfterHours) ?? 24
        )
    }
}
