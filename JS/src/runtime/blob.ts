// Blob, File, and FormData. Provider SDKs reference them (`instanceof FormData`, file uploads) even for JSON requests.

const g = globalThis as Record<string, unknown>;

type BlobPart = string | ArrayBuffer | ArrayBufferView | BlobPolyfill;

class BlobPolyfill {
	readonly #bytes: Uint8Array;
	readonly type: string;

	constructor(parts: BlobPart[] = [], options: { type?: string } = {}) {
		const chunks = parts.map((part) => {
			if (part instanceof BlobPolyfill) return part.#bytes;
			if (typeof part === "string") return new TextEncoder().encode(part);
			if (part instanceof ArrayBuffer) return new Uint8Array(part);
			return new Uint8Array(part.buffer, part.byteOffset, part.byteLength);
		});
		const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
		this.#bytes = new Uint8Array(total);
		let offset = 0;
		for (const chunk of chunks) {
			this.#bytes.set(chunk, offset);
			offset += chunk.byteLength;
		}
		this.type = (options.type ?? "").toLowerCase();
	}

	get size(): number {
		return this.#bytes.byteLength;
	}
	async arrayBuffer(): Promise<ArrayBuffer> {
		return this.#bytes.slice().buffer as ArrayBuffer;
	}
	async bytes(): Promise<Uint8Array> {
		return this.#bytes.slice();
	}
	async text(): Promise<string> {
		return new TextDecoder().decode(this.#bytes);
	}
	slice(start = 0, end = this.size, type = ""): BlobPolyfill {
		return new BlobPolyfill([this.#bytes.slice(start, end)], { type });
	}
	stream(): ReadableStream<Uint8Array> {
		const bytes = this.#bytes.slice();
		return new ReadableStream({
			start(controller) {
				controller.enqueue(bytes);
				controller.close();
			},
		});
	}
	get [Symbol.toStringTag](): string {
		return "Blob";
	}
}

class FilePolyfill extends BlobPolyfill {
	readonly name: string;
	readonly lastModified: number;
	constructor(parts: BlobPart[], name: string, options: { type?: string; lastModified?: number } = {}) {
		super(parts, options);
		this.name = String(name);
		this.lastModified = options.lastModified ?? Date.now();
	}
	get [Symbol.toStringTag](): string {
		return "File";
	}
}

type Entry = [string, string | FilePolyfill];

class FormDataPolyfill {
	#entries: Entry[] = [];

	#value(value: unknown, filename?: string): string | FilePolyfill {
		if (value instanceof FilePolyfill && filename === undefined) return value;
		if (value instanceof BlobPolyfill) return new FilePolyfill([value], filename ?? "blob", { type: value.type });
		return String(value);
	}
	append(name: string, value: unknown, filename?: string): void {
		this.#entries.push([String(name), this.#value(value, filename)]);
	}
	set(name: string, value: unknown, filename?: string): void {
		this.delete(name);
		this.append(name, value, filename);
	}
	get(name: string): string | FilePolyfill | null {
		return this.#entries.find(([key]) => key === name)?.[1] ?? null;
	}
	getAll(name: string): (string | FilePolyfill)[] {
		return this.#entries.filter(([key]) => key === name).map(([, value]) => value);
	}
	has(name: string): boolean {
		return this.#entries.some(([key]) => key === name);
	}
	delete(name: string): void {
		this.#entries = this.#entries.filter(([key]) => key !== name);
	}
	forEach(callback: (value: string | FilePolyfill, key: string, parent: FormDataPolyfill) => void): void {
		for (const [key, value] of this.#entries) callback(value, key, this);
	}
	*entries(): IterableIterator<Entry> {
		yield* this.#entries;
	}
	*keys(): IterableIterator<string> {
		for (const [key] of this.#entries) yield key;
	}
	*values(): IterableIterator<string | FilePolyfill> {
		for (const [, value] of this.#entries) yield value;
	}
	[Symbol.iterator](): IterableIterator<Entry> {
		return this.entries();
	}
	get [Symbol.toStringTag](): string {
		return "FormData";
	}
}

if (typeof g.Blob !== "function") g.Blob = BlobPolyfill;
if (typeof g.File !== "function") g.File = FilePolyfill;
if (typeof g.FormData !== "function") g.FormData = FormDataPolyfill;

export {};
