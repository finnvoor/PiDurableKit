// `node:sqlite` for pi-durable's SQLite adapter, backed by the host's SQLite (see `SQLiteDatabase.swift`).
import { native } from "../runtime/native.ts";

type Value = null | number | bigint | string | Uint8Array;

function bind(params: Value[]): unknown[] {
	return params.map((value) => (typeof value === "bigint" ? Number(value) : value));
}

class StatementSync {
	readonly #handle: number;
	readonly #sql: string;
	constructor(handle: number, sql: string) {
		this.#handle = handle;
		this.#sql = sql;
	}
	run(...params: Value[]): void {
		native.sqliteQuery(this.#handle, this.#sql, bind(params), "run");
	}
	get(...params: Value[]): unknown {
		return native.sqliteQuery(this.#handle, this.#sql, bind(params), "get") ?? undefined;
	}
	all(...params: Value[]): unknown[] {
		return native.sqliteQuery(this.#handle, this.#sql, bind(params), "all") as unknown[];
	}
}

export class DatabaseSync {
	readonly #handle: number;
	#open = true;
	constructor(path: string, options: { timeout?: number } = {}) {
		this.#handle = native.sqliteOpen(path, options.timeout ?? 0);
	}
	exec(sql: string): void {
		native.sqliteExec(this.#handle, sql);
	}
	prepare(sql: string): StatementSync {
		return new StatementSync(this.#handle, sql);
	}
	get isOpen(): boolean {
		return this.#open;
	}
	close(): void {
		if (!this.#open) return;
		this.#open = false;
		native.sqliteClose(this.#handle);
	}
}
