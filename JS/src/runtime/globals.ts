// Host-backed web globals that JavaScriptCore does not provide: timers, console, crypto, performance.
import { native, runtimeCallbacks } from "./native.ts";

const g = globalThis as Record<string, unknown>;

// MARK: Timers

type TimerCallback = (...args: unknown[]) => void;

class Timeout {
	readonly id: number;
	constructor(id: number) {
		this.id = id;
	}
	ref(): this {
		return this;
	}
	unref(): this {
		return this;
	}
	hasRef(): boolean {
		return true;
	}
	refresh(): this {
		return this;
	}
	[Symbol.toPrimitive](): number {
		return this.id;
	}
}

let nextTimerId = 1;
const timers = new Map<number, { callback: TimerCallback; args: unknown[]; interval?: number }>();

function timerId(handle: unknown): number | undefined {
	if (handle instanceof Timeout) return handle.id;
	if (typeof handle === "number") return handle;
	return undefined;
}

/** Node's rule: a delay that isn't a number from 1 to 2³¹−1 ms (NaN, Infinity, 0, negative, too large) is 1 ms. */
function nodeDelay(delay: unknown): number {
	const ms = Number(delay);
	return ms >= 1 && ms <= 2_147_483_647 ? ms : 1;
}

function schedule(callback: unknown, ms: number, args: unknown[], interval: boolean): Timeout {
	if (typeof callback !== "function") throw new TypeError("Timer callback must be a function");
	const id = nextTimerId++;
	timers.set(id, { callback: callback as TimerCallback, args, interval: interval ? ms : undefined });
	native.setTimer(id, ms);
	return new Timeout(id);
}

function clear(handle: unknown): void {
	const id = timerId(handle);
	if (id === undefined || !timers.delete(id)) return;
	native.clearTimer(id);
}

runtimeCallbacks.fireTimer = ((id: number) => {
	const timer = timers.get(id);
	if (timer === undefined) return;
	if (timer.interval === undefined) timers.delete(id);
	else native.setTimer(id, timer.interval);
	try {
		timer.callback(...timer.args);
	} catch (error) {
		reportError(error);
	}
}) as never;

g.setTimeout = (callback: unknown, delay?: unknown, ...args: unknown[]) => schedule(callback, nodeDelay(delay), args, false);
g.setInterval = (callback: unknown, delay?: unknown, ...args: unknown[]) => schedule(callback, nodeDelay(delay), args, true);
g.setImmediate = (callback: unknown, ...args: unknown[]) => schedule(callback, 0, args, false);
g.clearTimeout = clear;
g.clearInterval = clear;
g.clearImmediate = clear;
g.queueMicrotask = (callback: () => void) => {
	Promise.resolve().then(callback).catch(reportError);
};

// MARK: Console

function describe(value: unknown): string {
	if (typeof value === "string") return value;
	if (value instanceof Error) return value.stack ? `${value.name}: ${value.message}\n${value.stack}` : `${value.name}: ${value.message}`;
	if (typeof value === "bigint") return `${value}n`;
	if (typeof value === "function" || typeof value === "symbol" || value === undefined) return String(value);
	try {
		return JSON.stringify(value) ?? String(value);
	} catch {
		return String(value);
	}
}

function logger(level: "debug" | "info" | "warn" | "error") {
	return (...values: unknown[]) => native.log(level, values.map(describe).join(" "));
}

g.console = {
	debug: logger("debug"),
	log: logger("info"),
	info: logger("info"),
	warn: logger("warn"),
	error: logger("error"),
	trace: logger("debug"),
	dir: logger("debug"),
	assert: (condition: unknown, ...values: unknown[]) => {
		if (!condition) logger("error")("Assertion failed", ...values);
	},
	time: () => {},
	timeEnd: () => {},
	group: () => {},
	groupEnd: () => {},
};

export function reportError(error: unknown): void {
	native.log("error", `Uncaught ${describe(error)}`);
}
g.reportError = reportError;

// MARK: Crypto

function getRandomValues<T extends ArrayBufferView | null>(array: T): T {
	if (array === null || !ArrayBuffer.isView(array)) throw new TypeError("Expected an integer typed array");
	if (array.byteLength > 65536) throw new RangeError("Quota exceeded");
	native.randomBytes(new Uint8Array(array.buffer, array.byteOffset, array.byteLength));
	return array;
}

function randomUUID(): string {
	const bytes = getRandomValues(new Uint8Array(16));
	bytes[6] = (bytes[6]! & 0x0f) | 0x40;
	bytes[8] = (bytes[8]! & 0x3f) | 0x80;
	const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
	return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function bytesOf(data: BufferSource): Uint8Array {
	if (data instanceof ArrayBuffer) return new Uint8Array(data);
	return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
}

const subtle = {
	async digest(algorithm: string | { name: string }, data: BufferSource): Promise<ArrayBuffer> {
		const name = (typeof algorithm === "string" ? algorithm : algorithm.name).toUpperCase();
		if (name !== "SHA-256") throw new DOMException(`Unsupported digest algorithm ${name}`, "NotSupportedError");
		const digest = native.sha256(bytesOf(data));
		return digest.buffer.slice(digest.byteOffset, digest.byteOffset + digest.byteLength) as ArrayBuffer;
	},
};

g.crypto = { getRandomValues, randomUUID, subtle };

// MARK: Performance

const timeOrigin = native.now();
g.performance = {
	timeOrigin,
	now: () => native.now() - timeOrigin,
	mark: () => {},
	measure: () => {},
};

g.self = globalThis;
