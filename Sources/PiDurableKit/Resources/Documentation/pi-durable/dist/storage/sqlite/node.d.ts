import { type NodeSqliteDatabaseOptions } from "@earendil-works/chord/sqlite/node";
import { SqliteStorage, type SqliteStorageOptions } from "./storage.ts";
export { NodeSqliteDatabase, type NodeSqliteDatabaseOptions, openNodeSqliteDatabase, } from "@earendil-works/chord/sqlite/node";
/** Node SQLite connection settings plus durable storage options. */
export type NodeSqliteStorageOptions = NodeSqliteDatabaseOptions & SqliteStorageOptions;
/** Open or create file-backed durable storage using Node's built-in SQLite, optionally under a table prefix. */
export declare function openNodeSqliteStorage(path: string, options?: NodeSqliteStorageOptions): Promise<SqliteStorage>;
