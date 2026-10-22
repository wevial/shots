import Foundation
import SQLite3

public struct SQLiteError: LocalizedError, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A minimal wrapper over the SQLite C API.
///
/// Not thread-safe on its own: an actor (`Database` for the daemon, `ShotStore` for the
/// viewer) owns each instance and so uses it from one task at a time.
public final class SQLiteConnection {
    private var handle: OpaquePointer?

    /// Opens (creating if needed) a database for reading and writing.
    public init(path: String, busyTimeoutMs: Int32 = 5000) throws {
        handle = try Self.open(path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, busyTimeoutMs: busyTimeoutMs)
    }

    /// Opens an existing database read-only.
    public init(readOnlyPath path: String, busyTimeoutMs: Int32 = 2000) throws {
        handle = try Self.open(path, flags: SQLITE_OPEN_READONLY, busyTimeoutMs: busyTimeoutMs)
    }

    private static func open(_ path: String, flags: Int32, busyTimeoutMs: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(status)"
            sqlite3_close(db)
            throw SQLiteError(message: "Couldn't open \(path): \(message)")
        }
        sqlite3_busy_timeout(db, busyTimeoutMs)
        return db
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Closes the connection; anything run afterwards throws.
    public func close() {
        sqlite3_close(handle)
        handle = nil
    }

    /// Runs one or more statements that return nothing (schema, pragmas).
    public func execute(_ sql: String) throws {
        let db = try open()
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw SQLiteError(message: message.map { String(cString: $0) } ?? "exec failed")
        }
    }

    /// Runs one statement and returns how many rows it changed.
    @discardableResult
    public func run(_ sql: String, _ bindings: [Binding] = []) throws -> Int {
        _ = try query(sql, bindings) { _ in () }
        return Int(sqlite3_changes(try open()))
    }

    /// Runs `sql` with `?` bindings (numbered `?1` works too) and maps each row.
    public func query<T>(_ sql: String, _ bindings: [Binding] = [], row: (Row) throws -> T) throws -> [T] {
        let db = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }

        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case .int(let value): sqlite3_bind_int64(statement, position, value)
            case .double(let value): sqlite3_bind_double(statement, position, value)
            case .null: sqlite3_bind_null(statement, position)
            }
        }

        // Look column names up once per query rather than once per value read.
        var columns: [String: Int32] = [:]
        for i in 0..<sqlite3_column_count(statement) {
            columns[String(cString: sqlite3_column_name(statement, i))] = i
        }

        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: results.append(try row(Row(statement: statement, columns: columns)))
            case SQLITE_DONE: return results
            default: throw lastError()
            }
        }
    }

    private func open() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError(message: "the database is closed") }
        return handle
    }

    private func lastError() -> SQLiteError {
        SQLiteError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "the database is closed")
    }

    public enum Binding: Sendable {
        case text(String)
        case int(Int64)
        case double(Double)
        case null

        /// The value, or SQL `null` when it's nil.
        public static func nullable(_ value: String?) -> Binding { value.map { .text($0) } ?? .null }
        public static func nullable(_ value: Int64?) -> Binding { value.map { .int($0) } ?? .null }
        public static func nullable(_ value: Int?) -> Binding { value.map { .int(Int64($0)) } ?? .null }
        public static func nullable(_ value: Double?) -> Binding { value.map { .double($0) } ?? .null }
    }

    /// One result row. Columns are read by name so queries can use `select *`.
    public struct Row {
        let statement: OpaquePointer
        let columns: [String: Int32]

        private func index(of name: String) -> Int32? {
            guard let i = columns[name], sqlite3_column_type(statement, i) != SQLITE_NULL else { return nil }
            return i
        }

        public func string(_ name: String) -> String? {
            guard let i = index(of: name), let text = sqlite3_column_text(statement, i) else { return nil }
            return String(cString: text)
        }

        public func int(_ name: String) -> Int64? {
            index(of: name).map { sqlite3_column_int64(statement, $0) }
        }

        public func double(_ name: String) -> Double? {
            index(of: name).map { sqlite3_column_double(statement, $0) }
        }
    }
}

/// Tells SQLite to copy bound strings, since Swift may free them before the statement runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
