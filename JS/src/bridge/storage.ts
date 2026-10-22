// Storage backends chosen by Swift, including ones implemented in Swift (`CustomStorage`), plain Sessions without a
// Harness, and pi-durable's conformance suites run against Swift implementations.
import type { Context } from "@earendil-works/chord";
import { apply, type Op } from "@earendil-works/chord/delta";
import { createRegistry, createSession, MemoryStorage, type Storage, StorageRequestError } from "@earendil-works/pi-durable";
import { JsonlStorage } from "@earendil-works/pi-durable/storage/jsonl";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { createEnvConformance, createStorageConformance } from "@earendil-works/pi-durable/testing";
import type { StorageConformanceAssertions } from "@earendil-works/pi-durable/testing";
import { type Args, contextOf, emit, finish, host, hostSync, openStream, register, serializeError } from "./core.ts";
import { environmentOf, SandboxEnv } from "./env.ts";
import { hostTimer } from "./harness.ts";
import { HostSqliteDatabase } from "./sqlite.ts";
import { endings, type HarnessState, harnessState, harnesses } from "./state.ts";

/** pi-durable's `Storage` implemented in Swift, by its registration number. Records cross as JSON. */
class HostStorage implements Storage {
	readonly #storage: number;

	constructor(storage: number) {
		this.#storage = storage;
	}

	async #call<T>(operation: string, args: Args, context?: Context): Promise<T> {
		try {
			return await host<T>("storage.custom", { storage: this.#storage, operation, ...args }, context);
		} catch (error) {
			// Swift's `PiDurableError.storageRequestError` fails only this read, as pi-durable's `StorageRequestError` does.
			if ((error as { code?: string }).code === "storage_request") throw new StorageRequestError((error as Error).message);
			throw error;
		}
	}

	async #optional<T>(operation: string, args: Args, context?: Context): Promise<T | undefined> {
		return (await this.#call<T | null>(operation, args, context)) ?? undefined;
	}

	commit(writes: readonly unknown[], context: Context) {
		return this.#call("commit", { writes }, context) as never;
	}
	mintId() {
		return this.#call("mintId", {}) as never;
	}
	conversation(id: number, context: Context) {
		return this.#optional("conversation", { id }, context) as never;
	}
	scanConversations(query: unknown, limit: number, cursor: unknown, context: Context) {
		return this.#call("scanConversations", { query, limit, cursor: cursor ?? null }, context) as never;
	}
	entry(...args: unknown[]) {
		// `entry(id, context)` or `entry(conversationId, id, context)`.
		if (args.length >= 3) return this.#optional("entry", { conversationId: args[0], id: args[1] }, args[2] as Context) as never;
		return this.#optional("entry", { id: args[0] }, args[1] as Context) as never;
	}
	findLatestHeadMarker(conversationId: number, atOrBeforeEntryId: number | undefined, context: Context) {
		return this.#optional("findLatestHeadMarker", { conversationId, atOrBeforeEntryId: atOrBeforeEntryId ?? null }, context) as never;
	}
	scanEntries(query: unknown, limit: number, cursor: unknown, context: Context) {
		return this.#call("scanEntries", { query, limit, cursor: cursor ?? null }, context) as never;
	}
	task(id: number, context: Context) {
		return this.#optional("task", { id }, context) as never;
	}
	scanTasks(query: unknown, limit: number, cursor: unknown, context: Context) {
		return this.#call("scanTasks", { query, limit, cursor: cursor ?? null }, context) as never;
	}
	submission(id: number, context: Context) {
		return this.#optional("submission", { id }, context) as never;
	}
	scanSubmissions(query: unknown, limit: number, cursor: unknown, context: Context) {
		return this.#call("scanSubmissions", { query, limit, cursor: cursor ?? null }, context) as never;
	}
	submissionByRequest(conversationId: number, requestId: string, context: Context) {
		return this.#optional("submissionByRequest", { conversationId, requestId }, context) as never;
	}
	findDocument(address: unknown, at: unknown, context: Context) {
		return this.#optional("findDocument", { address, at }, context) as never;
	}
	document(id: number, at: unknown, context: Context) {
		return this.#optional("document", { id, at }, context) as never;
	}
	scanDocuments(query: unknown, limit: number, cursor: unknown, context: Context) {
		return this.#call("scanDocuments", { query, limit, cursor: cursor ?? null }, context) as never;
	}
	async close(context: Context) {
		await this.#call("close", {}, context);
	}
}

/** Opens the storage Swift describes (`Storage.specification`). */
export async function openStorage(spec: Args, context: Context): Promise<Storage> {
	switch (spec.kind) {
		case "sqlite":
			return openNodeSqliteStorage(spec.path, spec.prefix == null ? {} : { prefix: spec.prefix });
		case "jsonl":
			return JsonlStorage.open(
				spec.directory ?? "/",
				spec.environment == null ? new SandboxEnv(spec.path) : environmentOf(spec.environment, "/"),
				context,
				{ fsync: spec.fsync === true },
			);
		case "database":
			return SqliteStorage.open(new HostSqliteDatabase(spec.database), spec.prefix == null ? {} : { prefix: spec.prefix });
		case "custom":
			return new HostStorage(spec.storage) as unknown as Storage;
		default:
			return new MemoryStorage();
	}
}

/** Strict JSON equality, and the assertions pi-durable's conformance suites need. */
function equal(actual: unknown, expected: unknown, partial: boolean): boolean {
	if (actual === expected) return true;
	if (typeof actual !== "object" || typeof expected !== "object" || actual === null || expected === null) return false;
	if (Array.isArray(actual) !== Array.isArray(expected)) return false;
	if (Array.isArray(actual)) {
		const other = expected as unknown[];
		if (!partial && actual.length !== other.length) return false;
		return other.every((value, index) => equal(actual[index], value, partial));
	}
	const left = actual as Record<string, unknown>;
	const right = expected as Record<string, unknown>;
	const keys = Object.keys(right).filter((key) => right[key] !== undefined);
	if (!partial) {
		const leftKeys = Object.keys(left).filter((key) => left[key] !== undefined);
		if (leftKeys.length !== keys.length) return false;
	}
	return keys.every((key) => equal(left[key], right[key], partial));
}

const show = (value: unknown) => {
	try {
		return JSON.stringify(value);
	} catch {
		return String(value);
	}
};

const assertions: StorageConformanceAssertions = {
	ok(value, message) {
		if (!value) throw new Error(message ?? `Expected a truthy value, got ${show(value)}`);
	},
	strictEqual(actual, expected) {
		if (actual !== expected) throw new Error(`Expected ${show(expected)}, got ${show(actual)}`);
	},
	deepEqual(actual, expected) {
		if (!equal(actual, expected, false)) throw new Error(`Expected ${show(expected)}, got ${show(actual)}`);
	},
	partialDeepEqual(actual, expected) {
		if (!equal(actual, expected, true)) throw new Error(`Expected to contain ${show(expected)}, got ${show(actual)}`);
	},
	greaterThan(actual, expected) {
		if (!(actual > expected)) throw new Error(`Expected more than ${expected}, got ${actual}`);
	},
	async rejects(operation, messageIncludes) {
		try {
			await operation;
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			if (!message.includes(messageIncludes)) throw new Error(`Expected a rejection with "${messageIncludes}", got "${message}"`);
			return;
		}
		throw new Error(`Expected a rejection with "${messageIncludes}"`);
	},
};

/** Runs cases one by one, streaming `{ name, error }` for each. */
async function runCases(stream: number, cases: readonly { name: string; run(): Promise<void> }[], only: string[] | null) {
	for (const item of cases) {
		if (only !== null && !only.some((name) => item.name.includes(name))) continue;
		try {
			await item.run();
			emit(stream, { name: item.name, error: null });
		} catch (error) {
			emit(stream, { name: item.name, error: serializeError(error) });
		}
	}
}

register({
	/** A plain pi-durable Session (`createSession`) without a Harness: commits, documents, and commit publications. */
	"session.open": async (args, context) => {
		const storage = await openStorage(args.storage, context);
		const session = createSession(storage, {
			...(args.clock ? { now: () => hostSync<number>("harness.now", { harness: args.id }) } : {}),
			...(args.timer ? { setTimer: hostTimer(args.id) } : {}),
			...(args.documentRetentionMs == null
				? {}
				: { documentRetentionMs: args.documentRetentionMs >= 3.15e16 ? Number.POSITIVE_INFINITY : args.documentRetentionMs }),
		});
		endings.set(args.id, session.closed);
		harnesses.set(args.id, {
			id: args.id,
			harness: session as never,
			registry: createRegistry(),
			settings: { value: {} },
		} satisfies HarnessState);
	},
	/** Emits once, then ends, when the session or harness starts closing (`subscribeClose`). */
	"harness.closeEvents": (args) => {
		const stream = args.stream as number;
		const unsubscribe = harnessState(args.harness).harness.subscribeClose(() => {
			emit(stream, true);
			finish(stream);
		});
		openStream(stream, unsubscribe);
	},
	/** Emits `{ reason, error? }` once the session or harness has closed, Storage included (`Session.closed`). */
	"harness.closed": (args) => {
		const stream = args.stream as number;
		openStream(stream, () => undefined);
		const ending = endings.get(args.harness);
		if (ending === undefined) throw new Error("The harness is closed");
		void ending.then((end) => {
			emit(stream, end.reason === "failed" ? { reason: "failed", error: serializeError(end.error) } : { reason: "closed" });
			finish(stream);
		});
	},
	/** Applies Chord operations to a JSON value, as storage materializes documents. */
	"chord.apply": (args) => apply(args.value ?? undefined, args.ops as Op[]) ?? null,
	/** pi-durable's storage conformance cases against storages Swift opens, one per case. */
	"conformance.storage": (args) => {
		const stream = args.stream as number;
		openStream(stream, () => undefined);
		const cases = createStorageConformance({
			assertions,
			withStorage: async (use) => {
				const spec = await host<Args>("conformance.storage", { factory: args.factory });
				const storage = await openStorage(spec, contextOf(undefined));
				try {
					await use(storage);
				} finally {
					await storage.close(contextOf(undefined)).catch(() => undefined);
				}
			},
		});
		void runCases(stream, cases, args.only ?? null).then(
			() => finish(stream),
			(error) => finish(stream, error),
		);
	},
	/** pi-durable's `ExecutionEnv` conformance cases against environments Swift builds, one per case. */
	"conformance.env": (args) => {
		const stream = args.stream as number;
		openStream(stream, () => undefined);
		const cases = createEnvConformance({
			assertions,
			withEnv: async (use) => {
				const spec = await host<Args>("conformance.environment", { factory: args.factory });
				const env = environmentOf(spec, "/");
				try {
					await use(env);
				} finally {
					await env.cleanup(contextOf(undefined)).catch(() => undefined);
				}
			},
			...(args.shell == null ? {} : { shell: args.shell }),
			...(args.symlinks == null ? {} : { symlinks: args.symlinks }),
			...(args.listFiles == null ? {} : { listFiles: args.listFiles }),
		});
		void runCases(stream, cases, args.only ?? null).then(
			() => finish(stream),
			(error) => finish(stream, error),
		);
	},
});
