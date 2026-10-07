// The part of `node:crypto` pi-ai's OAuth flows use.

class Bytes extends Uint8Array {
	override toString(encoding?: string): string {
		if (encoding === "hex") return Array.from(this, (byte) => byte.toString(16).padStart(2, "0")).join("");
		if (encoding === "base64" || encoding === "base64url") {
			const base64 = btoa(String.fromCharCode(...this));
			return encoding === "base64" ? base64 : base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
		}
		return new TextDecoder().decode(this);
	}
}

export function randomBytes(size: number): Bytes {
	const bytes = new Bytes(size);
	crypto.getRandomValues(bytes);
	return bytes;
}

export function randomUUID(): string {
	return crypto.randomUUID();
}
