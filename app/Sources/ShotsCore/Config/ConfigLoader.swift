import Foundation

/// A config file that can't be used. The message starts with `config:` like the old daemon's.
public struct ConfigError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = "config: \(message)" }
    public var errorDescription: String? { message }
}

extension Config {
    /// `$SHOTS_CONFIG`, else ~/.config/shots/config.json.
    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["SHOTS_CONFIG"] ?? Paths.join(Paths.home(environment: environment), ".config/shots/config.json")
    }

    /// Loads the config, writing the defaults on first run so the file is discoverable.
    public static func load(from path: String = Config.path(), home: String = Paths.home()) throws -> Config {
        let base = Config.defaults(home: home)
        guard FileManager.default.fileExists(atPath: path) else {
            try writeDefaults(base, to: path)
            return try base.merging([:], home: home)
        }
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigError("\(path) is not readable: \(errorMessage(error))")
        }
        let user: JSONValue
        do {
            user = try JSONValue.parse(text)
        } catch {
            throw ConfigError("\(path) is not valid JSON: \(errorMessage(error))")
        }
        guard let object = user.objectValue else { throw ConfigError("\(path) must hold a JSON object") }
        return try base.merging(object, home: home)
    }

    /// The seed file leaves out dataDir, which people rarely need to move.
    private static func writeDefaults(_ config: Config, to path: String) throws {
        guard var seed = config.json.objectValue else { return }
        seed["dataDir"] = nil
        try FileManager.default.createDirectory(atPath: Paths.dirname(path), withIntermediateDirectories: true)
        try (JSONValue.object(seed).serialized(indent: 2) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Shallow-merges user JSON over this config (the two CLI backend objects merge one
    /// level deeper), expands `~` in the paths, and validates the result.
    public func merging(_ user: JSONObject, home: String = Paths.home()) throws -> Config {
        guard var merged = json.objectValue else { throw ConfigError("defaults are not an object") }
        for (key, value) in user {
            if ["claudeCode", "codex"].contains(key), case .object(let override) = value, var nested = merged[key]?.objectValue {
                for (k, v) in override { nested[k] = v }
                merged[key] = .object(nested)
            } else {
                merged[key] = value
            }
        }

        // Checked before decoding so the messages match the old daemon's.
        guard let backends = merged["backends"]?.arrayValue else { throw ConfigError("backends must be an array") }
        for backend in backends where backend.stringValue.flatMap(BackendName.init(rawValue:)) == nil {
            throw ConfigError("unknown backend \(backend.serialized())")
        }
        guard merged["categories"]?.arrayValue?.isEmpty == false else { throw ConfigError("categories must be a non-empty array") }

        var config: Config
        do {
            config = try JSONValue.object(merged).decode(Config.self)
        } catch let error as DecodingError {
            throw ConfigError(Self.describe(error))
        }
        config.inbox = Paths.resolve(Paths.expandHome(config.inbox, home: home))
        config.outputRoot = Paths.resolve(Paths.expandHome(config.outputRoot, home: home))
        config.dataDir = Paths.resolve(Paths.expandHome(config.dataDir, home: home))
        try config.validate()
        return config
    }

    /// The same rules as src/config.ts, including quietly adding `misc`, which the review
    /// path files into.
    public mutating func validate() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw ConfigError(message) }
        }
        try check(!categories.isEmpty, "categories must be a non-empty array")
        let slug = /^[a-z0-9][a-z0-9-]*$/
        try check(categories.allSatisfy { $0.wholeMatch(of: slug) != nil }, "categories must be lowercase slugs")
        if !categories.contains("misc") { categories.append("misc") }
        try check((0...1).contains(escalateBelowConfidence), "escalateBelowConfidence must be 0-1")
        try check((0...1).contains(reviewBelowConfidence), "reviewBelowConfidence must be 0-1")
        try check((1...2).contains(concurrency), "concurrency must be 1 or 2")
        try check(timeoutMs > 0, "timeoutMs must be positive")
        try check(cleanupAfterHours >= 0, "cleanupAfterHours must not be negative")
        try check(Paths.resolve(inbox) != Paths.resolve(outputRoot), "inbox and outputRoot must differ")
    }

    private static func describe(_ error: DecodingError) -> String {
        func key(_ path: [any CodingKey]) -> String {
            path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().trimmingPrefix(".").description
        }
        switch error {
        case .typeMismatch(let type, let context):
            return "\(key(context.codingPath)) must be \(Self.typeName(type))"
        case .valueNotFound(let type, let context):
            return "\(key(context.codingPath)) must be \(Self.typeName(type)), not null"
        case .keyNotFound(let missing, let context):
            return "\(key(context.codingPath + [missing])) is missing"
        case .dataCorrupted(let context):
            return "\(key(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }

    private static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: "a string"
        case is Int.Type: "an integer"
        case is Double.Type: "a number"
        case is Bool.Type: "true or false"
        default: type is any Collection.Type ? "an array or object" : "\(type)"
        }
    }
}
