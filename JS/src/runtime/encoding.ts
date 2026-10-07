// UTF-8 TextEncoder / TextDecoder (WHATWG Encoding, utf-8 only), including streaming decode.

const g = globalThis as Record<string, unknown>;

class TextEncoderPolyfill {
	readonly encoding = "utf-8";

	encode(input = ""): Uint8Array {
		const text = String(input);
		const out = new Uint8Array(text.length * 3);
		const { written } = this.#encodeInto(text, out);
		return out.slice(0, written);
	}

	encodeInto(input: string, destination: Uint8Array): { read: number; written: number } {
		return this.#encodeInto(String(input), destination);
	}

	#encodeInto(text: string, out: Uint8Array): { read: number; written: number } {
		let read = 0;
		let written = 0;
		const length = text.length;
		while (read < length) {
			let code = text.charCodeAt(read);
			let units = 1;
			if (code >= 0xd800 && code <= 0xdbff && read + 1 < length) {
				const next = text.charCodeAt(read + 1);
				if (next >= 0xdc00 && next <= 0xdfff) {
					code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
					units = 2;
				} else code = 0xfffd;
			} else if (code >= 0xd800 && code <= 0xdfff) code = 0xfffd;

			const size = code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
			if (written + size > out.length) break;
			if (size === 1) out[written++] = code;
			else if (size === 2) {
				out[written++] = 0xc0 | (code >> 6);
				out[written++] = 0x80 | (code & 0x3f);
			} else if (size === 3) {
				out[written++] = 0xe0 | (code >> 12);
				out[written++] = 0x80 | ((code >> 6) & 0x3f);
				out[written++] = 0x80 | (code & 0x3f);
			} else {
				out[written++] = 0xf0 | (code >> 18);
				out[written++] = 0x80 | ((code >> 12) & 0x3f);
				out[written++] = 0x80 | ((code >> 6) & 0x3f);
				out[written++] = 0x80 | (code & 0x3f);
			}
			read += units;
		}
		return { read, written };
	}
}

function toBytes(input: unknown): Uint8Array {
	if (input === undefined || input === null) return new Uint8Array(0);
	if (input instanceof Uint8Array) return input;
	if (input instanceof ArrayBuffer) return new Uint8Array(input);
	if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
	throw new TypeError("The provided value is not of type '(ArrayBuffer or ArrayBufferView)'");
}

class TextDecoderPolyfill {
	readonly encoding = "utf-8";
	readonly fatal: boolean;
	readonly ignoreBOM: boolean;
	#pending: number[] = [];
	#bomSeen = false;

	constructor(label = "utf-8", options: { fatal?: boolean; ignoreBOM?: boolean } = {}) {
		const normalized = String(label).trim().toLowerCase();
		if (normalized !== "utf-8" && normalized !== "utf8" && normalized !== "unicode-1-1-utf-8") {
			throw new RangeError(`The encoding label provided ('${label}') is not supported.`);
		}
		this.fatal = options.fatal === true;
		this.ignoreBOM = options.ignoreBOM === true;
	}

	decode(input?: unknown, options: { stream?: boolean } = {}): string {
		const incoming = toBytes(input);
		let bytes: Uint8Array;
		if (this.#pending.length > 0) {
			bytes = new Uint8Array(this.#pending.length + incoming.length);
			bytes.set(this.#pending, 0);
			bytes.set(incoming, this.#pending.length);
			this.#pending = [];
		} else bytes = incoming;

		const stream = options.stream === true;
		let result = "";
		let chunk: number[] = [];
		let index = 0;
		const length = bytes.length;

		const flush = () => {
			result += String.fromCharCode.apply(null, chunk);
			chunk = [];
		};
		const replacement = () => {
			if (this.fatal) throw new TypeError("The encoded data was not valid for encoding utf-8");
			chunk.push(0xfffd);
		};

		while (index < length) {
			const byte = bytes[index]!;
			let needed = 0;
			let code = 0;
			let lower = 0x80;
			let upper = 0xbf;
			if (byte < 0x80) {
				chunk.push(byte);
				index++;
				if (chunk.length >= 8192) flush();
				continue;
			} else if (byte >= 0xc2 && byte <= 0xdf) {
				needed = 1;
				code = byte & 0x1f;
			} else if (byte >= 0xe0 && byte <= 0xef) {
				if (byte === 0xe0) lower = 0xa0;
				if (byte === 0xed) upper = 0x9f;
				needed = 2;
				code = byte & 0x0f;
			} else if (byte >= 0xf0 && byte <= 0xf4) {
				if (byte === 0xf0) lower = 0x90;
				if (byte === 0xf4) upper = 0x8f;
				needed = 3;
				code = byte & 0x07;
			} else {
				replacement();
				index++;
				continue;
			}

			if (index + needed >= length) {
				// Possibly truncated sequence at the end of the input.
				let valid = true;
				for (let offset = 1; index + offset < length; offset++) {
					const next = bytes[index + offset]!;
					const lo = offset === 1 ? lower : 0x80;
					const hi = offset === 1 ? upper : 0xbf;
					if (next < lo || next > hi) {
						valid = false;
						break;
					}
				}
				if (valid && stream) {
					for (let offset = index; offset < length; offset++) this.#pending.push(bytes[offset]!);
					break;
				}
				if (valid) {
					replacement();
					break;
				}
			}

			let consumed = 1;
			let ok = true;
			for (let offset = 1; offset <= needed; offset++) {
				const next = bytes[index + offset];
				const lo = offset === 1 ? lower : 0x80;
				const hi = offset === 1 ? upper : 0xbf;
				if (next === undefined || next < lo || next > hi) {
					ok = false;
					break;
				}
				code = (code << 6) | (next & 0x3f);
				consumed++;
			}
			if (!ok) {
				replacement();
				index += consumed;
				continue;
			}
			index += consumed;
			if (code > 0xffff) {
				code -= 0x10000;
				chunk.push(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
			} else chunk.push(code);
			if (chunk.length >= 8192) flush();
		}
		flush();

		if (!this.#bomSeen && result.length > 0) {
			this.#bomSeen = true;
			if (!this.ignoreBOM && result.charCodeAt(0) === 0xfeff) result = result.slice(1);
		}
		if (!stream) {
			this.#bomSeen = false;
			if (this.#pending.length > 0) {
				this.#pending = [];
				if (this.fatal) throw new TypeError("The encoded data was not valid for encoding utf-8");
				result += "\ufffd";
			}
		}
		return result;
	}
}

if (typeof g.TextEncoder !== "function") g.TextEncoder = TextEncoderPolyfill;
if (typeof g.TextDecoder !== "function") g.TextDecoder = TextDecoderPolyfill;

export {};
