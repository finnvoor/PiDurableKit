/**
 * Functions installed on `globalThis.__native` by the Swift host (see `JSRuntime.swift`).
 * Everything crossing the boundary is a primitive, a JSON string, or a `Uint8Array`.
 */
export interface NativeHost {
	log(level: "debug" | "info" | "warn" | "error", message: string): void;
	now(): number;

	setTimer(id: number, delayMs: number): void;
	clearTimer(id: number): void;

	/** Fills `bytes` with cryptographically secure random bytes. */
	randomBytes(bytes: Uint8Array): void;

	fetchStart(id: number, url: string, method: string, headersJSON: string, body: string | Uint8Array | null): void;
	fetchCancel(id: number): void;

	/** Reply to a host → JS call started with `__bridge.call`. */
	reply(id: number, resultJSON: string | null, errorJSON: string | null): void;
	/** Start a JS → host call; the host answers with `__runtime.hostResolve` / `__runtime.hostReject`. */
	hostCall(id: number, method: string, argsJSON: string): void;
	hostCancel(id: number): void;
	/** Runs synchronous Swift code; returns `{"value": …}` or `{"error": …}` JSON. */
	hostCallSync(method: string, argsJSON: string): string;
	/** Deliver one item to a host stream. */
	emit(streamId: number, payloadJSON: string): void;
	/** Finish a host stream. */
	finish(streamId: number, errorJSON: string | null): void;

	sqliteOpen(path: string, timeoutMs: number): number;
	sqliteExec(handle: number, sql: string): void;
	sqliteQuery(handle: number, sql: string, params: unknown[], mode: "run" | "get" | "all"): unknown;
	sqliteClose(handle: number): void;
	createDirectory(path: string): void;

	/** SHA-256 of `bytes`. */
	sha256(bytes: Uint8Array): Uint8Array;

	httpListen(server: number, port: number): void;
	httpRespond(connection: number, status: number, headersJSON: string, body: string): void;
	httpClose(server: number): void;
	httpCloseConnections(server: number): void;

	// Files of the sandboxed environment. Each throws an Error whose `code` is a pi-durable `FileErrorCode`.
	fsStat(path: string, follow: boolean): string;
	fsReadFile(path: string): Uint8Array;
	fsReadRange(path: string, offset: number, length: number): Uint8Array;
	fsWrite(path: string, content: string | Uint8Array, append: boolean): void;
	fsTruncate(path: string, size: number): void;
	fsSync(path: string): void;
	fsRename(from: string, to: string): void;
	fsList(path: string): string;
	fsMkdir(path: string, recursive: boolean): void;
	fsRemove(path: string, recursive: boolean, force: boolean): void;
	fsRealpath(path: string): string;
}

declare global {
	// eslint-disable-next-line no-var
	var __native: NativeHost;
}

export const native: NativeHost = globalThis.__native;

/** Callbacks the host invokes; registered on `globalThis.__runtime`. */
export const runtimeCallbacks: Record<string, (...args: never[]) => unknown> = {};
(globalThis as Record<string, unknown>).__runtime = runtimeCallbacks;
