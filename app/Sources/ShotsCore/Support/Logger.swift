import Foundation

/// JSON-lines logging, one object per line: `{"t":…,"level":…,"msg":…, …fields}`.
///
/// Info and debug go to stdout, warnings and errors to stderr, which is how the old
/// LaunchAgent split them into ~/Library/Logs/shots. The app can pass its own `sink`.
public struct Logger: Sendable {
    public enum Level: String, Sendable, Comparable, CaseIterable {
        case debug, info, warn, error

        public static func < (a: Level, b: Level) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public typealias Sink = @Sendable (_ level: Level, _ line: String) -> Void

    public var minLevel: Level
    private let sink: Sink?

    /// `minLevel` defaults to `$SHOTS_LOG_LEVEL`, else info.
    public init(minLevel: Level? = nil, sink: Sink? = nil) {
        self.minLevel = minLevel
            ?? ProcessInfo.processInfo.environment["SHOTS_LOG_LEVEL"].flatMap(Level.init(rawValue:))
            ?? .info
        self.sink = sink ?? Logger.standardStreams
    }

    /// Drops everything. For tests.
    public static let silent = Logger(minLevel: .error, silent: ())

    private init(minLevel: Level, silent: Void) {
        self.minLevel = minLevel
        self.sink = nil
    }

    public func debug(_ msg: String, _ fields: JSONObject = [:]) { emit(.debug, msg, fields) }
    public func info(_ msg: String, _ fields: JSONObject = [:]) { emit(.info, msg, fields) }
    public func warn(_ msg: String, _ fields: JSONObject = [:]) { emit(.warn, msg, fields) }
    public func error(_ msg: String, _ fields: JSONObject = [:]) { emit(.error, msg, fields) }

    private func emit(_ level: Level, _ msg: String, _ fields: JSONObject) {
        guard let sink, level >= minLevel else { return }
        var line: JSONObject = ["t": .string(Timestamp.now()), "level": .string(level.rawValue), "msg": .string(msg)]
        for (key, value) in fields { line[key] = value }
        sink(level, JSONValue.object(line).serialized())
    }

    private static let standardStreams: Sink = { level, line in
        let handle: FileHandle = level >= .warn ? .standardError : .standardOutput
        handle.write(Data((line + "\n").utf8))
    }
}
