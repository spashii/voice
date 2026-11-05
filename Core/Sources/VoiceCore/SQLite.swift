import Foundation
import SQLite3

/// One SQLite connection with typed binds and reads. It does no locking of its own: each
/// store that owns one runs every call on its own serial queue.
final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw VoiceError.store("Can't open \(url.path): \(message)")
        }
        // The app and voice-cli both write to this file. A writer that finds the other's
        // transaction open waits for it instead of failing at once.
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw VoiceError.store(text)
        }
    }

    /// Runs a statement that returns no rows; returns how many rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: [Any?] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_changes(db))
    }

    func query<T>(_ sql: String, _ values: [Any?] = [], _ read: (SQLiteRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let statement else { throw lastError() }
            rows.append(try read(SQLiteRow(statement: statement)))
        }
        return rows
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    /// BEGIN IMMEDIATE takes the write lock up front, so a transaction that reads before it
    /// writes can't be overtaken by another process between the two.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ values: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, index, v)
            case let v as Bool: sqlite3_bind_int64(statement, index, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(statement, index, v)
            case let v as Date: sqlite3_bind_double(statement, index, v.timeIntervalSince1970)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func lastError() -> VoiceError {
        VoiceError.store(String(cString: sqlite3_errmsg(db)))
    }
}

/// The current row of a query, read by column index.
struct SQLiteRow {
    let statement: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }
    func string(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
    func text(_ i: Int32) -> String { string(i) ?? "" }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
    func optionalInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
    func optionalDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: double(i)) }
    func optionalDate(_ i: Int32) -> Date? { isNull(i) ? nil : date(i) }
}
