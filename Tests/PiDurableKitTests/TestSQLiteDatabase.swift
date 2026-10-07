import Foundation
import PiDurableKit
import SQLite3

/// A ``SQLiteDatabase`` written the way an app would: SQLite3 directly, operations serialized, transactions exclusive.
final class TestSQLiteDatabase: SQLiteDatabase, @unchecked Sendable {
    private var connection: OpaquePointer?
    private let lock = AsyncLock()
    private let counts = NSLock()
    private(set) var transactions = 0
    private(set) var rollbacks = 0

    init(path: String) throws {
        guard sqlite3_open(path, &connection) == SQLITE_OK else { throw SQLiteTestError(message: "open failed") }
    }

    func execute(_ sql: String) async throws { try await lock.run { try Raw(connection: self.connection).exec(sql) } }

    func run(_ sql: String, _ parameters: [SQLiteValue]) async throws {
        try await lock.run { _ = try Raw(connection: self.connection).query(sql, parameters) }
    }

    func get(_ sql: String, _ parameters: [SQLiteValue]) async throws -> SQLiteRow? {
        try await lock.run { try Raw(connection: self.connection).query(sql, parameters).first }
    }

    func all(_ sql: String, _ parameters: [SQLiteValue]) async throws -> [SQLiteRow] {
        try await lock.run { try Raw(connection: self.connection).query(sql, parameters) }
    }

    func transaction<T: Sendable>(_ body: @escaping @Sendable (any SQLiteExecutor) async throws -> T) async throws -> T {
        try await lock.run {
            let raw = Raw(connection: self.connection)
            try raw.exec("BEGIN IMMEDIATE")
            self.counts.withLock { self.transactions += 1 }
            do {
                let result = try await body(raw)
                try raw.exec("COMMIT")
                return result
            } catch {
                self.counts.withLock { self.rollbacks += 1 }
                try raw.exec("ROLLBACK")
                throw error
            }
        }
    }

    func close() async throws {
        try await lock.run {
            sqlite3_close(self.connection)
            self.connection = nil
        }
    }

    /// Unserialized access, used inside a transaction (which already holds the lock).
    struct Raw: SQLiteExecutor, @unchecked Sendable {
        let connection: OpaquePointer?

        func exec(_ sql: String) throws {
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
        }

        func execute(_ sql: String) async throws { try exec(sql) }
        func run(_ sql: String, _ parameters: [SQLiteValue]) async throws { _ = try query(sql, parameters) }
        func get(_ sql: String, _ parameters: [SQLiteValue]) async throws -> SQLiteRow? { try query(sql, parameters).first }
        func all(_ sql: String, _ parameters: [SQLiteValue]) async throws -> [SQLiteRow] { try query(sql, parameters) }

        func query(_ sql: String, _ parameters: [SQLiteValue]) throws -> [SQLiteRow] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in parameters.enumerated() {
                let position = Int32(index + 1)
                switch value {
                case .null: sqlite3_bind_null(statement, position)
                case .integer(let number): sqlite3_bind_int64(statement, position, number)
                case .real(let number): sqlite3_bind_double(statement, position, number)
                case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
                case .blob(let data):
                    _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) }
                }
            }
            var rows: [SQLiteRow] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error() }
                var row: SQLiteRow = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, column))
                        row[name] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column), count: count))
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }

        private func error() -> SQLiteTestError {
            SQLiteTestError(message: connection.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
        }
    }
}

struct SQLiteTestError: Error {
    let message: String
}

/// Runs operations one at a time, in arrival order.
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await operation()
    }
}
