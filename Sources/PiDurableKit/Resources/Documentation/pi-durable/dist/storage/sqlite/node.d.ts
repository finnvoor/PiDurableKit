import type { StatementSync } from "node:sqlite";
import { DatabaseSync } from "node:sqlite";
import type { SqliteDatabase, SqliteExecutor, SqliteValue } from "./database.ts";
import { SqliteStorage } from "./storage.ts";
/** Node SQLite connection settings for a durable storage file. */
export type NodeSqliteStorageOptions = {
    /** SQLite WAL auto-checkpoint threshold. SQLite and this adapter default to 1,000 pages; 0 disables it. */
    readonly walAutoCheckpointPages?: number;
    /** Time SQLite waits for a competing file lock. SQLite defaults to 0; this adapter defaults to 5,000 ms. */
    readonly busyTimeoutMs?: number;
};
/**
 * Executes SQL on one connection. Prepared statements are cached per connection by SQL text, so the
 * database and its transaction handles share them across transactions.
 */
declare abstract class NodeSqliteExecutor implements SqliteExecutor {
    protected readonly database: DatabaseSync;
    protected readonly statements: Map<string, StatementSync>;
    constructor(database: DatabaseSync, statements: Map<string, StatementSync>);
    exec(sql: string): Promise<void>;
    run(sql: string, ...params: SqliteValue[]): Promise<void>;
    get<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T | undefined>;
    all<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T[]>;
    protected abstract runOperation<T>(operation: () => T): Promise<T>;
    private statement;
}
/** `SqliteDatabase` adapter backed by Node's built-in `node:sqlite`. */
export declare class NodeSqliteDatabase extends NodeSqliteExecutor implements SqliteDatabase {
    private readonly access;
    private closed;
    constructor(database: DatabaseSync);
    transaction<T>(callback: (transaction: SqliteExecutor) => Promise<T>): Promise<T>;
    close(): Promise<void>;
    protected runOperation<T>(operation: () => T): Promise<T>;
}
/** Open and configure a Node-backed SQLite database facade. */
export declare function openNodeSqliteDatabase(path: string, options?: NodeSqliteStorageOptions): Promise<NodeSqliteDatabase>;
/** Open or create file-backed durable storage using Node's built-in SQLite. */
export declare function openNodeSqliteStorage(path: string, options?: NodeSqliteStorageOptions): Promise<SqliteStorage>;
export {};
