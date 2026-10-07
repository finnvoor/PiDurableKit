// Bridge plumbing shared by every module: Swift → JavaScript calls, JavaScript → Swift host calls, pushed streams,
// and scoped handles that let Swift reach JavaScript objects (transactions, tool calls, task runs) by number.
import { BACKGROUND_CONTEXT, withAbortSignal } from "@earendil-works/chord/context";
import type { Context } from "@earendil-works/chord";
import { native, runtimeCallbacks } from "../runtime/native.ts";

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
// biome-ignore lint/suspicious/noExplicitAny: arguments arrive as untyped JSON from Swift
export type Args = Record<string, any>;

// MARK: Methods (Swift → JavaScript)

/** Bridge methods by name. Modules register theirs with `register()`. */
export const methods: Record<string, (args: Args, context: Context) => unknown> = {};

export function register(entries: Record<string, (args: Args, context: Context) => unknown>): void {
	for (const [name, handler] of Object.entries(entries)) {
		if (name in methods) throw new Error(`Bridge method ${name} registered twice`);
		methods[name] = handler;
	}
}

export function serializeError(error: unknown): Json {
	if (error instanceof Error) {
		return {
			name: error.name,
			message: error.message,
			stack: error.stack ?? null,
			code: ((error as { code?: unknown }).code as Json) ?? null,
		};
	}
	return { name: "Error", message: String(error), stack: null, code: null };
}

const calls = new Map<number, AbortController>();

(globalThis as Record<string, unknown>).__bridge = {
	call(id: number, method: string, argsJSON: string): void {
		const controller = new AbortController();
		calls.set(id, controller);
		const context = withAbortSignal(controller.signal, BACKGROUND_CONTEXT);
		Promise.resolve()
			.then(() => {
				const handler = methods[method];
				if (handler === undefined) throw new Error(`Unknown bridge method ${method}`);
				return handler(JSON.parse(argsJSON) as Args, context);
			})
			.then(
				(result) => {
					calls.delete(id);
					native.reply(id, JSON.stringify(result ?? null), null);
				},
				(error) => {
					calls.delete(id);
					native.reply(id, null, JSON.stringify(serializeError(error)));
				},
			);
	},
	cancel(id: number): void {
		calls.get(id)?.abort();
	},
};

// MARK: Host calls (JavaScript → Swift)

let nextHostCall = 1;
const hostCalls = new Map<number, { resolve(value: unknown): void; reject(error: unknown): void }>();

runtimeCallbacks.hostResolve = ((id: number, json: string) => {
	const call = hostCalls.get(id);
	if (call === undefined) return;
	hostCalls.delete(id);
	call.resolve(json === "" ? undefined : JSON.parse(json));
}) as never;

runtimeCallbacks.hostReject = ((id: number, json: string) => {
	const call = hostCalls.get(id);
	if (call === undefined) return;
	hostCalls.delete(id);
	call.reject(hostError(json));
}) as never;

function hostError(json: string): Error {
	const info = JSON.parse(json) as { name?: string; message?: string };
	const error = new Error(info.message ?? "Host call failed");
	if (info.name) error.name = info.name;
	return error;
}

/** Calls Swift and awaits its answer. Aborting `context` cancels the Swift task. */
export function host<T>(method: string, args: Args, context?: Pick<Context, "abortSignal">): Promise<T> {
	const id = nextHostCall++;
	const signal = context?.abortSignal;
	return new Promise<T>((resolve, reject) => {
		if (signal?.aborted) {
			reject(signal.reason);
			return;
		}
		const onAbort = () => native.hostCancel(id);
		signal?.addEventListener("abort", onAbort, { once: true });
		hostCalls.set(id, {
			resolve: (value) => {
				signal?.removeEventListener("abort", onAbort);
				resolve(value as T);
			},
			reject: (error) => {
				signal?.removeEventListener("abort", onAbort);
				reject(error);
			},
		});
		native.hostCall(id, method, JSON.stringify(args));
	});
}

/**
 * Calls synchronous Swift code (migrations, task initial states, argument repair, the clock) and returns its answer.
 * The Swift side must not wait for anything.
 */
export function hostSync<T>(method: string, args: Args): T {
	const result = JSON.parse(native.hostCallSync(method, JSON.stringify(args))) as { value?: T; error?: string };
	if (result.error !== undefined) throw hostError(result.error);
	return result.value as T;
}

/** A context whose abort signal is `signal`, or the background context. */
export function contextOf(signal: AbortSignal | undefined): Context {
	return signal === undefined ? BACKGROUND_CONTEXT : withAbortSignal(signal, BACKGROUND_CONTEXT);
}

// MARK: Streams (JavaScript → Swift, push)

const streams = new Map<number, () => Promise<unknown> | void>();

export function openStream(stream: number, stop: () => Promise<unknown> | void): void {
	streams.set(stream, stop);
}

export function emit(stream: number, value: unknown): void {
	native.emit(stream, JSON.stringify(value));
}

export function finish(stream: number, error?: unknown): void {
	if (!streams.delete(stream)) return;
	native.finish(stream, error === undefined ? null : JSON.stringify(serializeError(error)));
}

register({
	"stream.stop": async (args) => {
		const stop = streams.get(args.stream);
		if (stop === undefined) return;
		await stop();
		finish(args.stream);
	},
});

// MARK: Scoped handles

let nextHandle = 1;
const handles = new Map<number, unknown>();

/** Makes `value` reachable from Swift by number until `close`. */
export function openHandle(value: unknown): number {
	const id = nextHandle++;
	handles.set(id, value);
	return id;
}

export function closeHandle(id: number): void {
	handles.delete(id);
}

/** Runs `body` with `value` reachable from Swift. */
export async function withHandle<T>(value: unknown, body: (handle: number) => Promise<T>): Promise<T> {
	const id = openHandle(value);
	try {
		return await body(id);
	} finally {
		closeHandle(id);
	}
}

export function handle<T>(id: number): T {
	if (!handles.has(id)) {
		throw Object.assign(new Error("This handle is no longer valid: its call, commit, or task phase has ended"), {
			name: "HandleExpired",
		});
	}
	return handles.get(id) as T;
}

/** JSON without `undefined` fields; `null` for `undefined`. */
export function plain<T>(value: T): Json {
	return value === undefined ? null : (JSON.parse(JSON.stringify(value)) as Json);
}
