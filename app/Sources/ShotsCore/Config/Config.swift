import Foundation

/// The classifiers the chain can use, by the names the config file uses.
public enum BackendName: String, Sendable, Codable, CaseIterable {
    case apple
    case claudeCode = "claude-code"
    case codex
    case rules
}

/// How to run one of the CLI agents.
public struct CliBackendConfig: Sendable, Equatable, Codable, JSONRepresentable {
    /// Executable name or absolute path, resolved against PATH at call time.
    public var binary: String
    public var model: String
    public var effort: String

    public init(binary: String, model: String, effort: String) {
        self.binary = binary
        self.model = model
        self.effort = effort
    }

    public var json: JSONValue { ["binary": .string(binary), "model": .string(model), "effort": .string(effort)] }
}

/// Everything in ~/.config/shots/config.json. The keys, defaults and validation match the
/// TypeScript daemon's src/config.ts, so either daemon can read the other's file.
public struct Config: Sendable, Equatable, Codable {
    public var inbox: String
    public var outputRoot: String
    public var categories: [String]
    /// One-line description per category, included in every prompt.
    public var categoryHints: [String: String]
    public var backends: [BackendName]
    public var escalateBelowConfidence: Double
    /// Per-backend ceiling on self-reported confidence, for models that always say 0.9.
    /// Keyed by backend name.
    public var confidenceCap: [String: Double]
    /// Final results under this go to misc with a review flag.
    public var reviewBelowConfidence: Double
    public var timeoutMs: Int
    public var allowCloud: Bool
    /// Bundle IDs or app names (case-insensitive) whose screenshots never reach cloud backends.
    public var cloudDenylist: [String]
    /// Hostnames (suffix match) whose browser screenshots never reach cloud backends.
    public var cloudDenylistDomains: [String]
    /// When the frontmost app is unknown (no context captured), allow cloud backends anyway.
    public var cloudWhenAppUnknown: Bool
    /// Bundle ID → category, for the local "rules" backend.
    public var appRules: [String: String]
    public var copyToClipboard: Bool
    /// Skip files whose metadata says they aren't screen captures.
    public var requireScreenCapture: Bool
    public var concurrency: Int
    public var maxAttempts: Int
    public var retryDelayMs: Int
    /// Files older than this at detection get no app context (it would describe the wrong moment).
    public var contextMaxAgeMs: Int
    public var ocrLanguages: [String]
    /// Bundle IDs or app names (case-insensitive) whose screenshots are usually scratch:
    /// coding agents, editors, terminals, simulators, apps you're building. A hint to the
    /// classifiers, not a verdict.
    public var scratchApps: [String]
    /// Scratch shots show up in Clean Up once they're this old.
    public var cleanupAfterHours: Int
    public var claudeCode: CliBackendConfig
    public var codex: CliBackendConfig
    public var dataDir: String

    // MARK: Derived

    public var timeout: Duration { .milliseconds(timeoutMs) }
    public var retryDelay: Duration { .milliseconds(retryDelayMs) }
    public var contextMaxAge: Duration { .milliseconds(contextMaxAgeMs) }
    /// Scratch shots captured before this show up in Clean Up.
    public func cleanupCutoff(now: Date = .now) -> Date { now.addingTimeInterval(-Double(cleanupAfterHours) * 3600) }
    public var databasePath: String { Paths.join(dataDir, "shots.db") }
    public var daemonStatusPath: String { Paths.join(dataDir, "daemon-status.json") }
}

// MARK: - Defaults

extension Config {
    public static let defaultCategories = [
        "code", "design", "ui-reference", "docs", "chat", "finance", "receipts",
        "shopping", "travel", "social", "errors", "misc",
    ]

    /// One-line meaning per category; small on-device models lean on these heavily.
    public static let defaultCategoryHints: [String: String] = [
        "code": "source code, terminals, diffs, pull requests, editors",
        "design": "design tools and mockups (Figma, Sketch), color, typography, layout work",
        "ui-reference": "a product's or website's interface kept as reference: dashboards, screens, flows",
        "docs": "documentation, articles, specs, reading material",
        "chat": "a messaging conversation (Slack, Messages, Discord, email threads)",
        "finance": "bank accounts, balances, investments, invoices to pay, budgets",
        "receipts": "a receipt or order confirmation for a completed purchase",
        "shopping": "product pages, carts, things to buy",
        "travel": "flights, hotels, maps, itineraries, boarding passes",
        "social": "social media posts and feeds",
        "errors": "an error message, crash, stack trace, failing build",
        "misc": "anything that fits nowhere else",
    ]

    /// Bundle ID → category, as an ordered list so the seed file keeps this order.
    static let defaultAppRules: [(String, String)] = [
        ("com.apple.dt.Xcode", "code"),
        ("com.microsoft.VSCode", "code"),
        ("com.todesktop.230313mzl4w4u92", "code"),
        ("com.apple.Terminal", "code"),
        ("com.googlecode.iterm2", "code"),
        ("com.mitchellh.ghostty", "code"),
        ("dev.zed.Zed", "code"),
        ("com.figma.Desktop", "design"),
        ("com.bohemiancoding.sketch3", "design"),
        ("com.tinyspeck.slackmacgap", "chat"),
        ("com.apple.MobileSMS", "chat"),
        ("com.hnc.Discord", "chat"),
        ("ru.keepcoder.Telegram", "chat"),
        ("net.whatsapp.WhatsApp", "chat"),
    ]

    public static let defaultScratchApps = [
        "com.anthropic.claudefordesktop", "com.openai.codex", "com.t3tools.t3code",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.microsoft.VSCode", "dev.zed.Zed",
        "com.apple.dt.Xcode", "com.apple.iphonesimulator", "com.google.android.studio",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.cmuxterm.app",
    ]

    /// A week: long enough that whatever the screenshot was for is done.
    public static let defaultCleanupAfterHours = 7 * 24

    public static func defaults(home: String = Paths.home()) -> Config {
        Config(
            inbox: Paths.join(home, "Screenshots/_inbox"),
            outputRoot: Paths.join(home, "Screenshots"),
            categories: defaultCategories,
            categoryHints: defaultCategoryHints,
            backends: [.apple, .claudeCode, .codex],
            escalateBelowConfidence: 0.6,
            confidenceCap: [:],
            reviewBelowConfidence: 0.6,
            timeoutMs: 30_000,
            allowCloud: true,
            cloudDenylist: [
                "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
                "com.apple.Passwords", "com.apple.keychainaccess",
            ],
            cloudDenylistDomains: [],
            cloudWhenAppUnknown: true,
            appRules: Dictionary(uniqueKeysWithValues: defaultAppRules),
            copyToClipboard: true,
            requireScreenCapture: true,
            concurrency: 1,
            maxAttempts: 3,
            retryDelayMs: 5 * 60_000,
            contextMaxAgeMs: 15_000,
            ocrLanguages: [],
            scratchApps: defaultScratchApps,
            cleanupAfterHours: defaultCleanupAfterHours,
            claudeCode: CliBackendConfig(binary: "claude", model: "sonnet", effort: "low"),
            codex: CliBackendConfig(binary: "codex", model: "gpt-6-luna", effort: "low"),
            dataDir: Paths.join(home, ".local/share/shots")
        )
    }
}

// MARK: - JSON

extension Config: JSONRepresentable {
    /// Keys in the order src/config.ts declares them, so `shots config` reads the same.
    /// Map-valued keys (categoryHints, appRules, confidenceCap) come out sorted.
    public var json: JSONValue {
        [
            "inbox": .string(inbox),
            "outputRoot": .string(outputRoot),
            "categories": JSONValue(categories),
            "categoryHints": orderedHints,
            "backends": .array(backends.map { .string($0.rawValue) }),
            "escalateBelowConfidence": .number(escalateBelowConfidence),
            "confidenceCap": .object(JSONObject(confidenceCap.sorted { $0.key < $1.key }.map { ($0.key, .number($0.value)) })),
            "reviewBelowConfidence": .number(reviewBelowConfidence),
            "timeoutMs": JSONValue(timeoutMs),
            "allowCloud": .bool(allowCloud),
            "cloudDenylist": JSONValue(cloudDenylist),
            "cloudDenylistDomains": JSONValue(cloudDenylistDomains),
            "cloudWhenAppUnknown": .bool(cloudWhenAppUnknown),
            "appRules": Self.ordered(appRules, first: Self.defaultAppRules.map(\.0)),
            "copyToClipboard": .bool(copyToClipboard),
            "requireScreenCapture": .bool(requireScreenCapture),
            "concurrency": JSONValue(concurrency),
            "maxAttempts": JSONValue(maxAttempts),
            "retryDelayMs": JSONValue(retryDelayMs),
            "contextMaxAgeMs": JSONValue(contextMaxAgeMs),
            "ocrLanguages": JSONValue(ocrLanguages),
            "scratchApps": JSONValue(scratchApps),
            "cleanupAfterHours": JSONValue(cleanupAfterHours),
            "claudeCode": claudeCode.json,
            "codex": codex.json,
            "dataDir": .string(dataDir),
        ]
    }

    /// Hints follow the category order (the order people wrote them in), then any extras.
    private var orderedHints: JSONValue { Self.ordered(categoryHints, first: categories) }

    /// `map` with the keys in `first` leading, in that order, then the rest sorted.
    private static func ordered(_ map: [String: String], first: [String]) -> JSONValue {
        var object = JSONObject()
        for key in first { if let value = map[key] { object[key] = .string(value) } }
        for (key, value) in map.sorted(by: { $0.key < $1.key }) where object[key] == nil { object[key] = .string(value) }
        return .object(object)
    }
}
