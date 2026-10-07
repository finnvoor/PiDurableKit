import Foundation
import os

/// A value stored in or bound to SQLite (pi-durable `SqliteValue`).
public enum SQLiteValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// A result row: column name to value.
public typealias SQLiteRow = [String: SQLiteValue]

/// SQL operations shared by a database and its transaction handles (pi-durable `SqliteExecutor`).
///
/// `execute` runs SQL text without bindings and may contain several statements. `run`, `get`, and `all` run one
/// statement with positional bindings; implementations may cache prepared statements by SQL text.
public protocol SQLiteExecutor: Sendable {
    func execute(_ sql: String) async throws
    func run(_ sql: String, _ parameters: [SQLiteValue]) async throws
    func get(_ sql: String, _ parameters: [SQLiteValue]) async throws -> SQLiteRow?
    func all(_ sql: String, _ parameters: [SQLiteValue]) async throws -> [SQLiteRow]
}

/// A SQLite database you implement, for pi-durable's portable SQLite storage (pi-durable `SqliteDatabase`): for
/// example one shared with the rest of your app, encrypted, or in an app group. Open it with
/// ``Storage/sqlite(database:)``.
///
/// The contract is pi-durable's: `transaction` passes `body` a handle that all of the transaction's work uses, and
/// must queue every other operation and transaction until it finishes. When `body` throws, roll back and rethrow its
/// error; if the rollback fails, throw a different error.
public protocol SQLiteDatabase: SQLiteExecutor {
    func transaction<T: Sendable>(_ body: @escaping @Sendable (any SQLiteExecutor) async throws -> T) async throws -> T
    func close() async throws
}

extension SQLiteValue {
    init(json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let value): self = .integer(value ? 1 : 0)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9.2e18 { self = .integer(Int64(value)) } else { self = .real(value) }
        case .string(let value): self = .text(value)
        case .object(let object):
            self = object["$blob"]?.stringValue.flatMap { Data(base64Encoded: $0) }.map(SQLiteValue.blob) ?? .null
        case .array: self = .null
        }
    }

    var json: JSONValue {
        switch self {
        case .null: .null
        case .integer(let value): .number(Double(value))
        case .real(let value): .number(value)
        case .text(let value): .string(value)
        case .blob(let data): ["$blob": .string(data.base64EncodedString())]
        }
    }
}

/// One transaction JavaScript drives on a Swift ``SQLiteDatabase``: the database's `transaction` runs in a task and
/// stays open until JavaScript ends it with a commit or a rollback.
final class SQLiteTransaction: Sendable {
    private struct State {
        var executor: (any SQLiteExecutor)?
        var ready: CheckedContinuation<any SQLiteExecutor, Error>?
        var end: CheckedContinuation<Bool, Never>?
        var commit: Bool?
    }

    private struct Rollback: Error {}

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let completion = OSAllocatedUnfairLock<Task<Void, Error>?>(initialState: nil)

    var executor: (any SQLiteExecutor)? { state.withLock { $0.executor } }

    /// Starts the transaction and returns once its handle is ready.
    func begin(on database: any SQLiteDatabase) async throws {
        _ = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<any SQLiteExecutor, Error>) in
            state.withLock { $0.ready = ready }
            let task = Task {
                do {
                    try await database.transaction { executor in
                        let ready = self.state.withLock { state -> CheckedContinuation<any SQLiteExecutor, Error>? in
                            state.executor = executor
                            defer { state.ready = nil }
                            return state.ready
                        }
                        ready?.resume(returning: executor)
                        let commit = await withCheckedContinuation { (end: CheckedContinuation<Bool, Never>) in
                            let decided = self.state.withLock { state -> Bool? in
                                if state.commit == nil { state.end = end }
                                return state.commit
                            }
                            if let decided { end.resume(returning: decided) }
                        }
                        if !commit { throw Rollback() }
                    }
                } catch {
                    let ready = self.state.withLock { state -> CheckedContinuation<any SQLiteExecutor, Error>? in
                        defer { state.ready = nil }
                        return state.ready
                    }
                    ready?.resume(throwing: error)
                    throw error
                }
            }
            completion.withLock { $0 = task }
        }
    }

    /// Commits or rolls back, and returns once the database's transaction has finished.
    func end(commit: Bool) async throws {
        let end = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            state.commit = commit
            defer { state.end = nil }
            return state.end
        }
        end?.resume(returning: commit)
        guard let task = completion.withLock({ $0 }) else { return }
        do {
            try await task.value
        } catch is Rollback where !commit {
            // The rollback the caller asked for.
        }
    }
}
