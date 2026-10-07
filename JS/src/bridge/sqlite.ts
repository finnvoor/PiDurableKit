// pi-durable's portable SQLite storage over a database implemented in Swift (`SQLiteDatabase`), the "asynchronous
// SqliteDatabase facade" its README describes for runtimes without node:sqlite.
import type { SqliteDatabase, SqliteExecutor, SqliteValue } from "@earendil-works/pi-durable/storage/sqlite";
import { host } from "./core.ts";

type Wire = null | number | string | { $blob: string };

function toBase64(bytes: Uint8Array): string {
	let binary = "";
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary);
}

function encode(value: SqliteValue): Wire {
	if (value instanceof Uint8Array) return { $blob: toBase64(value) };
	if (typeof value === "bigint") return Number(value);
	return value;
}

function decodeRow(row: Record<string, Wire> | null): Record<string, SqliteValue> | undefined {
	if (row === null) return undefined;
	const decoded: Record<string, SqliteValue> = {};
	for (const [key, value] of Object.entries(row)) {
		decoded[key] =
			value !== null && typeof value === "object" ? Uint8Array.from(atob(value.$blob), (char) => char.charCodeAt(0)) : value;
	}
	return decoded;
}

class HostSqliteExecutor implements SqliteExecutor {
	constructor(
		protected readonly database: number,
		protected readonly transactionId: number | null,
	) {}

	async exec(sql: string): Promise<void> {
		await host("sqlite.exec", { database: this.database, transaction: this.transactionId, sql });
	}
	async run(sql: string, ...params: SqliteValue[]): Promise<void> {
		await host("sqlite.run", { database: this.database, transaction: this.transactionId, sql, params: params.map(encode) });
	}
	async get<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T | undefined> {
		const row = await host<Record<string, Wire> | null>("sqlite.get", {
			database: this.database,
			transaction: this.transactionId,
			sql,
			params: params.map(encode),
		});
		return decodeRow(row) as T | undefined;
	}
	async all<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T[]> {
		const rows = await host<Record<string, Wire>[]>("sqlite.all", {
			database: this.database,
			transaction: this.transactionId,
			sql,
			params: params.map(encode),
		});
		return rows.map((row) => decodeRow(row) as T);
	}
}

export class HostSqliteDatabase extends HostSqliteExecutor implements SqliteDatabase {
	constructor(database: number) {
		super(database, null);
	}

	async transaction<T>(callback: (transaction: SqliteExecutor) => Promise<T>): Promise<T> {
		const transaction = await host<number>("sqlite.begin", { database: this.database });
		let result: T;
		try {
			result = await callback(new HostSqliteExecutor(this.database, transaction));
		} catch (error) {
			// Roll back, then reject with the callback's error; a failed rollback rejects with its own error.
			await host("sqlite.end", { database: this.database, transaction, commit: false });
			throw error;
		}
		await host("sqlite.end", { database: this.database, transaction, commit: true });
		return result;
	}

	async close(): Promise<void> {
		await host("sqlite.close", { database: this.database });
	}
}
