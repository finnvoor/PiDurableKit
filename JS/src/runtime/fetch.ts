// WHATWG fetch over URLSession: Headers, Request, Response, and fetch() with streaming response bodies.
import { native, runtimeCallbacks } from "./native.ts";

const g = globalThis as Record<string, unknown>;

type HeadersInit = Headers | Iterable<readonly [string, string]> | Record<string, string | readonly string[] | undefined>;

function normalizeName(name: string): string {
	const value = String(name);
	if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(value)) throw new TypeError(`Invalid header name: "${value}"`);
	return value.toLowerCase();
}

function normalizeValue(value: unknown): string {
	return String(value).replace(/^[\t\n\r ]+|[\t\n\r ]+$/g, "");
}

class HeadersPolyfill {
	#map = new Map<string, string[]>();

	constructor(init?: HeadersInit | null) {
		if (init === undefined || init === null) return;
		if (init instanceof HeadersPolyfill) {
			for (const [name, value] of init) this.append(name, value);
		} else if (typeof (init as Iterable<unknown>)[Symbol.iterator] === "function") {
			for (const pair of init as Iterable<readonly [string, string]>) {
				if (pair.length !== 2) throw new TypeError("Header pairs must contain exactly two items");
				this.append(pair[0], pair[1]);
			}
		} else {
			for (const [name, value] of Object.entries(init as Record<string, unknown>)) {
				if (value === undefined) continue;
				if (Array.isArray(value)) for (const item of value) this.append(name, item);
				else this.append(name, value);
			}
		}
	}

	append(name: string, value: unknown): void {
		const key = normalizeName(name);
		const list = this.#map.get(key);
		if (list) list.push(normalizeValue(value));
		else this.#map.set(key, [normalizeValue(value)]);
	}
	set(name: string, value: unknown): void {
		this.#map.set(normalizeName(name), [normalizeValue(value)]);
	}
	get(name: string): string | null {
		const list = this.#map.get(normalizeName(name));
		return list === undefined ? null : list.join(", ");
	}
	getSetCookie(): string[] {
		return [...(this.#map.get("set-cookie") ?? [])];
	}
	has(name: string): boolean {
		return this.#map.has(normalizeName(name));
	}
	delete(name: string): void {
		this.#map.delete(normalizeName(name));
	}
	forEach(callback: (value: string, name: string, headers: HeadersPolyfill) => void, thisArg?: unknown): void {
		for (const [name, value] of this) callback.call(thisArg, value, name, this);
	}
	*entries(): IterableIterator<[string, string]> {
		const names = [...this.#map.keys()].sort();
		for (const name of names) yield [name, this.get(name)!];
	}
	*keys(): IterableIterator<string> {
		for (const [name] of this.entries()) yield name;
	}
	*values(): IterableIterator<string> {
		for (const [, value] of this.entries()) yield value;
	}
	[Symbol.iterator](): IterableIterator<[string, string]> {
		return this.entries();
	}
	get [Symbol.toStringTag](): string {
		return "Headers";
	}
}

type Headers = HeadersPolyfill;
type BodyInit = string | ArrayBuffer | ArrayBufferView | URLSearchParams | ReadableStream<Uint8Array> | null | undefined;

const encoder = new TextEncoder();

function bodyToStream(body: BodyInit): ReadableStream<Uint8Array> | null {
	if (body === null || body === undefined) return null;
	if (body instanceof ReadableStream) return body;
	const bytes = bodyToBytes(body);
	return new ReadableStream<Uint8Array>({
		start(controller) {
			if (bytes.length > 0) controller.enqueue(bytes);
			controller.close();
		},
	});
}

function bodyToBytes(body: Exclude<BodyInit, ReadableStream | null | undefined>): Uint8Array {
	if (typeof body === "string") return encoder.encode(body);
	if (body instanceof ArrayBuffer) return new Uint8Array(body.slice(0));
	if (ArrayBuffer.isView(body)) return new Uint8Array(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
	if (typeof URLSearchParams === "function" && body instanceof URLSearchParams) return encoder.encode(body.toString());
	return encoder.encode(String(body));
}

function contentTypeFor(body: BodyInit): string | undefined {
	if (typeof body === "string") return "text/plain;charset=UTF-8";
	if (typeof URLSearchParams === "function" && body instanceof URLSearchParams) return "application/x-www-form-urlencoded;charset=UTF-8";
	return undefined;
}

async function readAll(stream: ReadableStream<Uint8Array> | null): Promise<Uint8Array> {
	if (stream === null) return new Uint8Array(0);
	const reader = stream.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		chunks.push(value);
		total += value.byteLength;
	}
	const out = new Uint8Array(total);
	let offset = 0;
	for (const chunk of chunks) {
		out.set(chunk, offset);
		offset += chunk.byteLength;
	}
	return out;
}

abstract class Body {
	#stream: ReadableStream<Uint8Array> | null;
	#used = false;
	constructor(stream: ReadableStream<Uint8Array> | null) {
		this.#stream = stream;
	}
	get body(): ReadableStream<Uint8Array> | null {
		return this.#stream;
	}
	get bodyUsed(): boolean {
		return this.#used || (this.#stream?.locked ?? false);
	}
	protected consume(): Promise<Uint8Array> {
		if (this.bodyUsed) return Promise.reject(new TypeError("Body has already been used"));
		this.#used = true;
		return readAll(this.#stream);
	}
	protected teeBody(): ReadableStream<Uint8Array> | null {
		if (this.#stream === null) return null;
		const [a, b] = this.#stream.tee();
		this.#stream = a;
		return b;
	}
	async arrayBuffer(): Promise<ArrayBuffer> {
		const bytes = await this.consume();
		return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
	}
	async bytes(): Promise<Uint8Array> {
		return this.consume();
	}
	async text(): Promise<string> {
		return new TextDecoder().decode(await this.consume());
	}
	async json(): Promise<unknown> {
		return JSON.parse(await this.text());
	}
}

type RequestInit = {
	method?: string;
	headers?: HeadersInit;
	body?: BodyInit;
	signal?: AbortSignal | null;
	redirect?: string;
	credentials?: string;
	cache?: string;
	mode?: string;
	keepalive?: boolean;
	duplex?: string;
};

class RequestPolyfill extends Body {
	readonly url: string;
	readonly method: string;
	readonly headers: Headers;
	readonly signal: AbortSignal;
	readonly redirect: string;
	readonly credentials: string;
	readonly cache: string;
	readonly mode: string;

	constructor(input: string | URL | RequestPolyfill, init: RequestInit = {}) {
		const source = input instanceof RequestPolyfill ? input : undefined;
		const body = init.body !== undefined ? init.body : source ? source.teeBody() : null;
		super(bodyToStream(body));
		this.url = source ? source.url : String(input);
		this.method = (init.method ?? source?.method ?? "GET").toUpperCase();
		this.headers = new HeadersPolyfill(init.headers ?? source?.headers);
		const type = contentTypeFor(init.body);
		if (type !== undefined && !this.headers.has("content-type")) this.headers.set("content-type", type);
		this.signal = init.signal ?? source?.signal ?? new AbortController().signal;
		this.redirect = init.redirect ?? source?.redirect ?? "follow";
		this.credentials = init.credentials ?? source?.credentials ?? "same-origin";
		this.cache = init.cache ?? source?.cache ?? "default";
		this.mode = init.mode ?? source?.mode ?? "cors";
	}

	clone(): RequestPolyfill {
		return new RequestPolyfill(this);
	}
}

type ResponseInit = { status?: number; statusText?: string; headers?: HeadersInit };

class ResponsePolyfill extends Body {
	readonly status: number;
	readonly statusText: string;
	readonly headers: Headers;
	readonly type: string = "default";
	readonly redirected: boolean = false;
	url = "";

	constructor(body: BodyInit = null, init: ResponseInit = {}) {
		super(bodyToStream(body));
		this.status = init.status ?? 200;
		this.statusText = init.statusText ?? "";
		this.headers = new HeadersPolyfill(init.headers);
		const type = contentTypeFor(body);
		if (type !== undefined && !this.headers.has("content-type")) this.headers.set("content-type", type);
	}

	get ok(): boolean {
		return this.status >= 200 && this.status < 300;
	}

	clone(): ResponsePolyfill {
		const copy = new ResponsePolyfill(this.teeBody(), { status: this.status, statusText: this.statusText, headers: this.headers });
		copy.url = this.url;
		return copy;
	}

	static json(data: unknown, init: ResponseInit = {}): ResponsePolyfill {
		const headers = new HeadersPolyfill(init.headers);
		if (!headers.has("content-type")) headers.set("content-type", "application/json");
		return new ResponsePolyfill(JSON.stringify(data), { ...init, headers });
	}

	static error(): ResponsePolyfill {
		return new ResponsePolyfill(null, { status: 0 });
	}
}

// MARK: fetch

type PendingFetch = {
	resolve(response: ResponsePolyfill): void;
	reject(error: unknown): void;
	controller?: ReadableStreamDefaultController<Uint8Array>;
	settled: boolean;
	finished: boolean;
	cleanup(): void;
};

let nextFetchId = 1;
const pending = new Map<number, PendingFetch>();

runtimeCallbacks.fetchResponse = ((id: number, status: number, statusText: string, url: string, headersJSON: string) => {
	const request = pending.get(id);
	if (request === undefined || request.settled) return;
	request.settled = true;
	const body = new ReadableStream<Uint8Array>({
		start(controller) {
			request.controller = controller;
		},
		cancel() {
			if (request.finished) return;
			request.finished = true;
			pending.delete(id);
			request.cleanup();
			native.fetchCancel(id);
		},
	});
	const nullBody = status === 101 || status === 204 || status === 205 || status === 304;
	const response = new ResponsePolyfill(nullBody ? null : body, {
		status,
		statusText,
		headers: JSON.parse(headersJSON) as [string, string][],
	});
	response.url = url;
	request.resolve(response);
}) as never;

runtimeCallbacks.fetchData = ((id: number, chunk: Uint8Array) => {
	const request = pending.get(id);
	if (request?.controller === undefined || request.finished) return;
	try {
		request.controller.enqueue(chunk);
	} catch {
		// The consumer cancelled the stream.
	}
}) as never;

runtimeCallbacks.fetchEnd = ((id: number) => {
	const request = pending.get(id);
	if (request === undefined) return;
	pending.delete(id);
	request.finished = true;
	request.cleanup();
	try {
		request.controller?.close();
	} catch {
		// Already closed or cancelled.
	}
}) as never;

runtimeCallbacks.fetchError = ((id: number, message: string) => {
	const request = pending.get(id);
	if (request === undefined) return;
	pending.delete(id);
	request.finished = true;
	request.cleanup();
	const error = new TypeError(`fetch failed: ${message}`);
	if (!request.settled) {
		request.settled = true;
		request.reject(error);
	} else {
		try {
			request.controller?.error(error);
		} catch {
			// Already closed or cancelled.
		}
	}
}) as never;

async function fetchPolyfill(input: string | URL | RequestPolyfill, init?: RequestInit): Promise<ResponsePolyfill> {
	const request = new RequestPolyfill(input, init);
	const signal = request.signal;
	if (signal.aborted) throw signal.reason;

	let body: Uint8Array | string | null = null;
	if (request.body !== null) {
		if (init?.body !== undefined && typeof init.body === "string") body = init.body;
		else body = await readAll(request.body);
	}

	const id = nextFetchId++;
	return new Promise<ResponsePolyfill>((resolve, reject) => {
		const onAbort = () => {
			const entry = pending.get(id);
			if (entry === undefined) return;
			pending.delete(id);
			entry.finished = true;
			native.fetchCancel(id);
			const reason = signal.reason ?? new DOMException("This operation was aborted", "AbortError");
			if (!entry.settled) {
				entry.settled = true;
				reject(reason);
			} else {
				try {
					entry.controller?.error(reason);
				} catch {
					// Already closed or cancelled.
				}
			}
		};
		pending.set(id, {
			resolve,
			reject,
			settled: false,
			finished: false,
			cleanup: () => signal.removeEventListener("abort", onAbort),
		});
		signal.addEventListener("abort", onAbort);
		native.fetchStart(id, request.url, request.method, JSON.stringify([...request.headers]), body);
	});
}

g.Headers = HeadersPolyfill;
g.Request = RequestPolyfill;
g.Response = ResponsePolyfill;
g.fetch = fetchPolyfill;
