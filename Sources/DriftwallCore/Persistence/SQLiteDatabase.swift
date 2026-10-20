import Foundation
import SQLite3

public enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public struct DatabaseError: LocalizedError, Equatable {
    public var code: Int32
    public var message: String
    public var sql: String?

    public var errorDescription: String? {
        if let sql { return "Database error \(code): \(message) (\(sql.prefix(80)))" }
        return "Database error \(code): \(message)"
    }
}

public struct SQLRow {
    fileprivate var columns: [String: SQLValue]

    public subscript(_ name: String) -> SQLValue { columns[name] ?? .null }

    public func string(_ name: String) -> String? {
        switch self[name] {
        case .text(let s): return s
        case .integer(let i): return String(i)
        case .real(let d): return String(d)
        default: return nil
        }
    }

    public func int(_ name: String) -> Int64? {
        switch self[name] {
        case .integer(let i): return i
        case .real(let d): return Int64(d)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }

    public func double(_ name: String) -> Double? {
        switch self[name] {
        case .real(let d): return d
        case .integer(let i): return Double(i)
        case .text(let s): return Double(s)
        default: return nil
        }
    }

    public func data(_ name: String) -> Data? {
        if case .blob(let d) = self[name] { return d }
        return nil
    }

    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }

    public func date(_ name: String) -> Date? { double(name).map(Date.init(timeIntervalSince1970:)) }
}

/// A minimal, synchronous wrapper around the system SQLite library.
/// All access is serialized through a lock so the wrapper can be shared across threads.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (creating if needed) the database at `url`, or an in-memory database when `url` is nil.
    public init(url: URL?) throws {
        self.url = url
        let path = url?.path ?? ":memory:"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(db)
            throw DatabaseError(code: rc, message: message, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
        try execute("PRAGMA foreign_keys = ON;")
        if url != nil { try execute("PRAGMA journal_mode = WAL;") }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version;").first?.int("user_version")).flatMap { $0 }.map(Int.init) ?? 0 }
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    /// Runs one or more statements without parameters.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw DatabaseError(code: rc, message: message, sql: sql)
        }
    }

    /// Runs a single statement with bound parameters.
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError(rc, sql) }
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError(rc, sql) }
            var columns: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                columns[name] = columnValue(statement, index)
            }
            rows.append(SQLRow(columns: columns))
        }
        return rows
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Quick structural check used at startup to detect a damaged database file.
    public func integrityCheck() -> Bool {
        (try? query("PRAGMA quick_check;").first?.string("quick_check")) == "ok"
    }

    // MARK: - Private

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else { throw lastError(rc, sql) }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch value {
            case .null: bindResult = sqlite3_bind_null(statement, index)
            case .integer(let i): bindResult = sqlite3_bind_int64(statement, index, i)
            case .real(let d): bindResult = sqlite3_bind_double(statement, index, d)
            case .text(let s): bindResult = sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .blob(let data):
                bindResult = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            }
            if bindResult != SQLITE_OK {
                sqlite3_finalize(statement)
                throw lastError(bindResult, sql)
            }
        }
        return statement
    }

    private func columnValue(_ statement: OpaquePointer?, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    private func lastError(_ code: Int32, _ sql: String) -> DatabaseError {
        DatabaseError(code: code, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
}

extension SQLValue {
    public init(_ string: String?) { self = string.map { .text($0) } ?? .null }
    public init(_ date: Date?) { self = date.map { .real($0.timeIntervalSince1970) } ?? .null }
    public init(_ data: Data?) { self = data.map { .blob($0) } ?? .null }
    public init(_ bool: Bool) { self = .integer(bool ? 1 : 0) }
    public init(_ int: Int) { self = .integer(Int64(int)) }
}
