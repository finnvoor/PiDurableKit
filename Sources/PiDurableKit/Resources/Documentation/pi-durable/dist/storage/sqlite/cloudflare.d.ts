import type { SqliteDatabase, SqliteExecutor, SqliteValue } from "./database.ts";
import { SqliteStorage } from "./storage.ts";
/** Values a Durable Object SQL binding accepts and returns. */
type DurableObjectSqlValue = ArrayBuffer | string | number | null;
/**
 * The parts of a SQLite-backed Durable Object's `ctx.storage` this adapter uses, typed structurally so the package
 * needs no Workers type dependency.
 */
export type DurableObjectSqliteStorage = {
    readonly sql: {
        exec(query: string, ...bindings: DurableObjectSqlValue[]): {
            toArray(): Record<string, DurableObjectSqlValue>[];
        };
    };
    transaction<T>(closure: () => Promise<T>): Promise<T>;
};
/** Executes SQL through `ctx.storage.sql`, which has no separate prepare step. */
declare class DurableObjectSqliteExecutor implements SqliteExecutor {
    protected readonly storage: DurableObjectSqliteStorage;
    constructor(storage: DurableObjectSqliteStorage);
    exec(sql: string): Promise<void>;
    run(sql: string, ...params: SqliteValue[]): Promise<void>;
    get<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T | undefined>;
    all<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T[]>;
    /** Throws when this handle may no longer run SQL. */
    protected check(): void;
}
/**
 * `SqliteDatabase` adapter for the SQLite storage of a Cloudflare Durable Object. Integers are JavaScript numbers;
 * binding a `bigint` outside the safe integer range throws.
 */
export declare class DurableObjectSqliteDatabase extends DurableObjectSqliteExecutor implements SqliteDatabase {
    private readonly queue;
    exec(sql: string): Promise<void>;
    run(sql: string, ...params: SqliteValue[]): Promise<void>;
    get<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T | undefined>;
    all<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T[]>;
    /** `ctx.storage.transaction()` commits when the callback resolves and rolls back when it rejects. */
    transaction<T>(callback: (transaction: SqliteExecutor) => Promise<T>): Promise<T>;
    /** Waits for queued work. The Durable Object owns its storage, so nothing else closes. */
    close(): Promise<void>;
}
/** Open durable storage on a SQLite-backed Durable Object's `ctx.storage`. */
export declare function openDurableObjectSqliteStorage(storage: DurableObjectSqliteStorage): Promise<SqliteStorage>;
export {};
