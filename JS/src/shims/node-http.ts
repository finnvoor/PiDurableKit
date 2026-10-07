// A loopback `node:http` server for pi-ai's OAuth redirect handlers, backed by Network.framework
// (see `LoopbackServer.swift`). Supports what the OAuth flows use: one handler, `writeHead`/`end`, `listen`,
// `address`, `close`, `closeAllConnections`, and `error` events.
import { native, runtimeCallbacks } from "../runtime/native.ts";

type Listener = (...args: any[]) => void;

class Emitter {
	#listeners = new Map<string, { listener: Listener; once: boolean }[]>();
	on(event: string, listener: Listener): this {
		this.#listeners.set(event, [...(this.#listeners.get(event) ?? []), { listener, once: false }]);
		return this;
	}
	addListener(event: string, listener: Listener): this {
		return this.on(event, listener);
	}
	once(event: string, listener: Listener): this {
		this.#listeners.set(event, [...(this.#listeners.get(event) ?? []), { listener, once: true }]);
		return this;
	}
	off(event: string, listener: Listener): this {
		this.#listeners.set(event, (this.#listeners.get(event) ?? []).filter((entry) => entry.listener !== listener));
		return this;
	}
	removeListener(event: string, listener: Listener): this {
		return this.off(event, listener);
	}
	emit(event: string, ...args: unknown[]): boolean {
		const listeners = this.#listeners.get(event) ?? [];
		this.#listeners.set(event, listeners.filter((entry) => !entry.once));
		for (const { listener } of listeners) listener(...args);
		return listeners.length > 0;
	}
}

class IncomingMessage {
	constructor(
		readonly method: string,
		readonly url: string,
		readonly headers: Record<string, string>,
	) {}
}

class ServerResponse {
	#status = 200;
	#headers: Record<string, string> = {};
	#ended = false;
	constructor(readonly connection: number) {}
	setHeader(name: string, value: string): void {
		this.#headers[name.toLowerCase()] = String(value);
	}
	writeHead(status: number, headers: Record<string, string> = {}): this {
		this.#status = status;
		for (const [name, value] of Object.entries(headers)) this.setHeader(name, value);
		return this;
	}
	end(body = ""): void {
		if (this.#ended) return;
		this.#ended = true;
		native.httpRespond(this.connection, this.#status, JSON.stringify(this.#headers), String(body));
	}
}

let nextServer = 1;
const servers = new Map<number, Server>();

class Server extends Emitter {
	readonly #id = nextServer++;
	readonly #handler: (request: IncomingMessage, response: ServerResponse) => void;
	#port: number | undefined;
	#host = "127.0.0.1";

	constructor(handler: (request: IncomingMessage, response: ServerResponse) => void) {
		super();
		this.#handler = handler;
	}

	listen(port: number, host?: string | (() => void), callback?: () => void): this {
		if (typeof host === "function") {
			callback = host;
			host = undefined;
		}
		this.#host = host ?? "127.0.0.1";
		servers.set(this.#id, this);
		if (callback) this.once("listening", callback);
		native.httpListen(this.#id, port ?? 0);
		return this;
	}

	address(): { address: string; family: string; port: number } | null {
		return this.#port === undefined ? null : { address: this.#host, family: "IPv4", port: this.#port };
	}

	close(callback?: (error?: Error) => void): this {
		servers.delete(this.#id);
		native.httpClose(this.#id);
		this.#port = undefined;
		callback?.();
		this.emit("close");
		return this;
	}

	closeAllConnections(): void {
		native.httpCloseConnections(this.#id);
	}

	closeIdleConnections(): void {
		native.httpCloseConnections(this.#id);
	}

	static listening(id: number, port: number): void {
		const server = servers.get(id);
		if (server === undefined) return;
		server.#port = port;
		server.emit("listening");
	}

	static failed(id: number, message: string): void {
		const server = servers.get(id);
		if (server === undefined) return;
		servers.delete(id);
		server.emit("error", Object.assign(new Error(message), { code: "EADDRINUSE" }));
	}

	static request(id: number, connection: number, method: string, url: string, headersJSON: string): void {
		const server = servers.get(id);
		const response = new ServerResponse(connection);
		if (server === undefined) {
			response.writeHead(503).end();
			return;
		}
		server.#handler(new IncomingMessage(method, url, JSON.parse(headersJSON)), response);
	}
}

runtimeCallbacks.httpListening = Server.listening as never;
runtimeCallbacks.httpFailed = Server.failed as never;
runtimeCallbacks.httpRequest = Server.request as never;

export function createServer(handler: (request: IncomingMessage, response: ServerResponse) => void): Server {
	return new Server(handler);
}

export default { createServer };
