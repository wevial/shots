import Foundation
import SQLite3

public struct SQLiteError: LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

/// A minimal wrapper over the SQLite C API: just enough to run read-only queries.
/// Not thread-safe on its own; `ShotStore` (an actor) owns the only instance.
final class SQLiteConnection {
    private let handle: OpaquePointer

    init(readOnlyPath path: String, busyTimeoutMs: Int32 = 2000) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(status)"
            sqlite3_close(db)
            throw SQLiteError(message: "Couldn't open \(path): \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, busyTimeoutMs)
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs `sql` with positional `?` bindings and maps each row.
    func query<T>(_ sql: String, _ bindings: [Binding] = [], row: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }

        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case .int(let value): sqlite3_bind_int64(statement, position, value)
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

    private func lastError() -> SQLiteError {
        SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
    }

    enum Binding {
        case text(String)
        case int(Int64)
    }

    /// One result row. Columns are read by name so queries can use `select *`.
    struct Row {
        let statement: OpaquePointer
        let columns: [String: Int32]

        private func index(of name: String) -> Int32? { columns[name] }

        func string(_ name: String) -> String? {
            guard let i = index(of: name), sqlite3_column_type(statement, i) != SQLITE_NULL,
                  let text = sqlite3_column_text(statement, i) else { return nil }
            return String(cString: text)
        }

        func int(_ name: String) -> Int64? {
            guard let i = index(of: name), sqlite3_column_type(statement, i) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement, i)
        }

        func double(_ name: String) -> Double? {
            guard let i = index(of: name), sqlite3_column_type(statement, i) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(statement, i)
        }
    }
}

/// Tells SQLite to copy bound strings, since Swift may free them before the statement runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
