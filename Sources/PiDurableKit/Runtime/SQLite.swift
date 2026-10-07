import Foundation
import JavaScriptCore
import SQLite3

struct SQLiteError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection backing pi-durable's portable SQLite storage through the `node:sqlite` shim.
/// Prepared statements are cached by SQL text. Only used on the engine's queue.
final class SQLiteConnection {
    private var database: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String, busyTimeout: Double) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &database, flags, nil)
        guard status == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close_v2(database)
            database = nil
            throw SQLiteError(message: "Could not open SQLite database at \(path): \(message)")
        }
        if busyTimeout > 0 { sqlite3_busy_timeout(database, Int32(busyTimeout)) }
    }

    deinit { close() }

    func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let database { sqlite3_close_v2(database) }
        database = nil
    }

    func execute(_ sql: String) throws {
        let database = try open()
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw SQLiteError(message: message)
        }
    }

    /// Runs one statement; `mode` is `run` (no result), `get` (first row or `undefined`), or `all` (array of rows).
    func query(_ sql: String, parameters: JSValue, mode: String, in context: JSContext) throws -> JSValue {
        let statement = try prepare(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(parameters, to: statement)

        var rows: [JSValue] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw SQLiteError(message: lastError) }
            if mode == "run" { continue }
            rows.append(row(statement, in: context))
            if mode == "get" { break }
        }

        switch mode {
        case "get": return rows.first ?? JSValue(undefinedIn: context)
        case "all":
            let array = JSValue(newArrayIn: context)!
            for (index, row) in rows.enumerated() { array.setValue(row, at: index) }
            return array
        default: return JSValue(undefinedIn: context)
        }
    }

    private var lastError: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite database is closed"
    }

    private func open() throws -> OpaquePointer {
        guard let database else { throw SQLiteError(message: "SQLite database is closed") }
        return database
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(try open(), sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError(message: lastError)
        }
        statements[sql] = statement
        return statement
    }

    private func bind(_ parameters: JSValue, to statement: OpaquePointer) throws {
        guard parameters.isArray else { return }
        let count = Int(parameters.objectForKeyedSubscript("length").toInt32())
        for index in 0..<count {
            let value = parameters.atIndex(index)!
            let position = Int32(index + 1)
            let status: Int32
            if value.isNull || value.isUndefined {
                status = sqlite3_bind_null(statement, position)
            } else if value.isBoolean {
                status = sqlite3_bind_int64(statement, position, value.toBool() ? 1 : 0)
            } else if value.isNumber {
                let number = value.toDouble()
                if number.rounded() == number, abs(number) < 9.2e18 {
                    status = sqlite3_bind_int64(statement, position, Int64(number))
                } else {
                    status = sqlite3_bind_double(statement, position, number)
                }
            } else if value.isString {
                status = sqlite3_bind_text(statement, position, value.toString(), -1, SQLITE_TRANSIENT)
            } else if let data = TypedArray.data(of: value) {
                status = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
                }
            } else {
                throw SQLiteError(message: "Unsupported SQLite parameter \(value.toString() ?? "")")
            }
            guard status == SQLITE_OK else { throw SQLiteError(message: lastError) }
        }
    }

    private func row(_ statement: OpaquePointer, in context: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: context)!
        for column in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, column))
            let value: JSValue
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER:
                value = JSValue(double: Double(sqlite3_column_int64(statement, column)), in: context)
            case SQLITE_FLOAT:
                value = JSValue(double: sqlite3_column_double(statement, column), in: context)
            case SQLITE_TEXT:
                value = JSValue(object: String(cString: sqlite3_column_text(statement, column)), in: context)
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, column))
                let data = count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column), count: count)
                value = TypedArray.makeUint8Array(data, in: context) ?? JSValue(nullIn: context)
            default:
                value = JSValue(nullIn: context)
            }
            object.setValue(value, forProperty: name)
        }
        return object
    }
}

/// Open connections by handle. Only used on the engine's queue, from JavaScriptCore callbacks.
final class SQLiteConnections: @unchecked Sendable {
    private var connections: [Int: SQLiteConnection] = [:]
    private var nextID = 1

    func open(path: String, busyTimeout: Double) throws -> Int {
        let connection = try SQLiteConnection(path: path, busyTimeout: busyTimeout)
        let id = nextID
        nextID += 1
        connections[id] = connection
        return id
    }

    func connection(_ id: Int) throws -> SQLiteConnection {
        guard let connection = connections[id] else { throw SQLiteError(message: "SQLite database is closed") }
        return connection
    }

    func close(_ id: Int) {
        connections.removeValue(forKey: id)?.close()
    }
}
