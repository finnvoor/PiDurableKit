// Event, EventTarget, DOMException, AbortController, and AbortSignal.

const g = globalThis as Record<string, unknown>;

class DOMExceptionPolyfill extends Error {
	static readonly ABORT_ERR = 20;
	static readonly TIMEOUT_ERR = 23;
	readonly code: number;
	constructor(message = "", name = "Error") {
		super(message);
		Object.defineProperty(this, "name", { value: name, configurable: true, writable: true });
		this.code = name === "AbortError" ? 20 : name === "TimeoutError" ? 23 : 0;
	}
}
if (typeof g.DOMException !== "function") g.DOMException = DOMExceptionPolyfill;
const DOMExceptionClass = g.DOMException as typeof DOMExceptionPolyfill;

class EventPolyfill {
	readonly type: string;
	readonly bubbles: boolean;
	readonly cancelable: boolean;
	readonly timeStamp = Date.now();
	defaultPrevented = false;
	target: unknown = null;
	currentTarget: unknown = null;
	#stopped = false;
	constructor(type: string, init: { bubbles?: boolean; cancelable?: boolean } = {}) {
		this.type = String(type);
		this.bubbles = init.bubbles === true;
		this.cancelable = init.cancelable === true;
	}
	preventDefault(): void {
		if (this.cancelable) this.defaultPrevented = true;
	}
	stopPropagation(): void {}
	stopImmediatePropagation(): void {
		this.#stopped = true;
	}
	get immediatePropagationStopped(): boolean {
		return this.#stopped;
	}
}

type Listener = { callback: unknown; once: boolean };

class EventTargetPolyfill {
	#listeners = new Map<string, Listener[]>();

	addEventListener(type: string, callback: unknown, options?: boolean | { once?: boolean; signal?: AbortSignal }): void {
		if (callback === null || callback === undefined) return;
		const once = typeof options === "object" && options?.once === true;
		const signal = typeof options === "object" ? options?.signal : undefined;
		if (signal?.aborted) return;
		const list = this.#listeners.get(type) ?? [];
		if (list.some((listener) => listener.callback === callback)) return;
		list.push({ callback, once });
		this.#listeners.set(type, list);
		signal?.addEventListener("abort", () => this.removeEventListener(type, callback), { once: true });
	}

	removeEventListener(type: string, callback: unknown): void {
		const list = this.#listeners.get(type);
		if (list === undefined) return;
		const index = list.findIndex((listener) => listener.callback === callback);
		if (index >= 0) list.splice(index, 1);
	}

	dispatchEvent(event: EventPolyfill): boolean {
		event.target = this;
		event.currentTarget = this;
		const handler = (this as unknown as Record<string, unknown>)[`on${event.type}`];
		const list = [...(this.#listeners.get(event.type) ?? [])];
		if (typeof handler === "function") list.unshift({ callback: handler, once: false });
		for (const listener of list) {
			if (listener.once) this.removeEventListener(event.type, listener.callback);
			try {
				if (typeof listener.callback === "function") listener.callback.call(this, event);
				else (listener.callback as { handleEvent(event: unknown): void }).handleEvent(event);
			} catch (error) {
				(g.reportError as (error: unknown) => void)(error);
			}
			if (event.immediatePropagationStopped) break;
		}
		return !event.defaultPrevented;
	}
}

if (typeof g.Event !== "function") g.Event = EventPolyfill;
if (typeof g.EventTarget !== "function") g.EventTarget = EventTargetPolyfill;

const EventClass = g.Event as typeof EventPolyfill;
const EventTargetClass = g.EventTarget as typeof EventTargetPolyfill;

const createSignal = Symbol("createSignal");
const abortSignal = Symbol("abort");

class AbortSignalPolyfill extends EventTargetClass {
	#aborted = false;
	#reason: unknown = undefined;
	onabort: ((event: unknown) => void) | null = null;

	constructor(token?: symbol) {
		super();
		if (token !== createSignal) throw new TypeError("Illegal constructor");
	}

	static [createSignal](): AbortSignalPolyfill {
		return new AbortSignalPolyfill(createSignal);
	}

	get aborted(): boolean {
		return this.#aborted;
	}

	get reason(): unknown {
		return this.#reason;
	}

	throwIfAborted(): void {
		if (this.#aborted) throw this.#reason;
	}

	[abortSignal](reason: unknown): void {
		if (this.#aborted) return;
		this.#aborted = true;
		this.#reason = reason === undefined ? new DOMExceptionClass("This operation was aborted", "AbortError") : reason;
		this.dispatchEvent(new EventClass("abort"));
	}

	static abort(reason?: unknown): AbortSignalPolyfill {
		const signal = AbortSignalPolyfill[createSignal]();
		signal[abortSignal](reason);
		return signal;
	}

	static timeout(milliseconds: number): AbortSignalPolyfill {
		const signal = AbortSignalPolyfill[createSignal]();
		setTimeout(() => signal[abortSignal](new DOMExceptionClass("The operation timed out.", "TimeoutError")), milliseconds);
		return signal;
	}

	static any(signals: Iterable<AbortSignalPolyfill>): AbortSignalPolyfill {
		const result = AbortSignalPolyfill[createSignal]();
		const list = [...signals];
		for (const signal of list) {
			if (signal.aborted) {
				result[abortSignal](signal.reason);
				return result;
			}
		}
		const onAbort = function (this: AbortSignalPolyfill) {
			result[abortSignal](this.reason);
			for (const signal of list) signal.removeEventListener("abort", onAbort);
		};
		for (const signal of list) signal.addEventListener("abort", onAbort);
		return result;
	}
}

class AbortControllerPolyfill {
	readonly signal = AbortSignalPolyfill[createSignal]();
	abort(reason?: unknown): void {
		this.signal[abortSignal](reason);
	}
}

if (typeof g.AbortSignal !== "function") {
	g.AbortSignal = AbortSignalPolyfill;
	g.AbortController = AbortControllerPolyfill;
}

export {};
