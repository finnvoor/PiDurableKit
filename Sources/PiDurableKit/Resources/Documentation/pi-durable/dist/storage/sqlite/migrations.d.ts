import type { SqliteDatabase } from "./database.ts";
export type SqliteMigration = {
    readonly version: number;
    readonly statements: readonly string[];
};
/** Immutable, ordered schema history. Append new migrations after the initial schema ships. */
export declare const SQLITE_MIGRATIONS: readonly SqliteMigration[];
export declare const CURRENT_SQLITE_SCHEMA_VERSION: number;
/** Apply all pending schema migrations atomically. */
export declare function applySqliteMigrations(database: SqliteDatabase, migrations?: readonly SqliteMigration[]): Promise<void>;
