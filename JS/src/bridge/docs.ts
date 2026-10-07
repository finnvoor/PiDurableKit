// Application documents defined from Swift: scopes, keyed families, rewindable history, and migrations.
import type { Context, JsonValue } from "@earendil-works/chord";
import {
	type ConversationId,
	defineDoc,
	defineDocFamily,
	type DocumentReader,
	type EntryId,
	type JsonObject,
	type TaskId,
	type Tx,
} from "@earendil-works/pi-durable";
import { type Args, hostSync } from "./core.ts";

/** A document definition sent by Swift (`Document.specification`). */
export type DocSpec = {
	kind: string;
	version: number;
	scope: "conversation" | "session" | "task";
	history?: "latest" | "rewindable";
	fork?: "current" | "initial" | "asOf";
	keyed?: boolean;
	initial: JsonObject;
	migrates?: boolean;
	/** Family members start from Swift's `initialForSeed(seed)` instead of `initial`. */
	seeded?: boolean;
	/** Swift decides `checkpointWhen`. */
	checkpoints?: boolean;
};

/** Where a document lives: the session, a conversation, or a task, plus a family key. */
export type DocOwner = { session: true } | { conversation: number } | { task: number };

// biome-ignore lint/suspicious/noExplicitAny: tokens are typed per call site by pi-durable's overloads
type AnyToken = any;

/**
 * Tokens are defined once per definition and shared by every harness, like pi-durable's module-level definitions.
 * A new version of a kind is a new definition; pi-durable checks it against what storage recorded.
 */
const tokens = new Map<string, AnyToken>();

export function docToken(spec: DocSpec): AnyToken {
	const key = JSON.stringify(spec);
	const existing = tokens.get(key);
	if (existing !== undefined) return existing;
	const initial = JSON.stringify(spec.initial);
	const semantics =
		spec.scope === "conversation"
			? { scope: "conversation", history: spec.history ?? "latest", fork: spec.fork ?? "current" }
			: { scope: spec.scope };
	const migrate = spec.migrates
		? (value: JsonObject, fromVersion: number) => hostSync<JsonObject>("doc.migrate", { kind: spec.kind, value, fromVersion })
		: undefined;
	const checkpointWhen = spec.checkpoints
		? (value: JsonObject, ops: readonly unknown[], info: { deltasSinceBase: number }) =>
				hostSync<boolean>("doc.checkpoint", { kind: spec.kind, value, ops, deltasSinceBase: info.deltasSinceBase })
		: undefined;
	const definition = {
		kind: spec.kind,
		version: spec.version,
		...semantics,
		...(migrate === undefined ? {} : { migrate }),
		...(checkpointWhen === undefined ? {} : { checkpointWhen }),
	};
	const familyInitial = spec.seeded
		? (seed: JsonValue) => hostSync<JsonObject>("doc.initial", { kind: spec.kind, seed: seed ?? null })
		: () => JSON.parse(initial);
	const token = spec.keyed
		? defineDocFamily({ ...definition, family: true, initial: familyInitial } as never)
		: defineDoc({ ...definition, initial: () => JSON.parse(initial) } as never);
	tokens.set(key, token);
	return token;
}

/** The trailing address arguments of pi-durable's document calls for `owner` and `key`. */
function address(spec: DocSpec, owner: DocOwner, key: string | undefined, forWrite: boolean, seed: unknown = null): unknown[] {
	const target: unknown[] =
		"session" in owner ? [] : "conversation" in owner ? [owner.conversation as ConversationId] : [owner.task as TaskId];
	const expected = spec.scope === "session" ? "session" in owner : spec.scope === "conversation" ? "conversation" in owner : "task" in owner;
	if (!expected) throw new Error(`Document ${spec.kind} lives in the ${spec.scope} scope`);
	if (spec.keyed) {
		if (key === undefined) throw new Error(`Document ${spec.kind} is keyed: pass a key`);
		// Family members are created from the seed when absent.
		return forWrite ? [...target, key, seed ?? null] : [...target, key];
	}
	if (key !== undefined) throw new Error(`Document ${spec.kind} is not keyed`);
	return target;
}

export function ownerOf(args: Args): DocOwner {
	const owner = args.owner as Args;
	if (owner.session) return { session: true };
	if (owner.conversation !== undefined) return { conversation: owner.conversation };
	return { task: owner.task };
}

/** Committed value, or the initial value when absent. */
export async function readDoc(reader: DocumentReader, args: Args, context: Context): Promise<JsonValue> {
	const spec = args.doc as DocSpec;
	const token = docToken(spec);
	const at = args.asOf as EntryId | undefined;
	const target = address(spec, ownerOf(args), args.key ?? undefined, false);
	const value =
		at === undefined || at === null
			? await (reader.snapshot as AnyToken).call(reader, token, ...target, context)
			: await (reader.snapshotAsOf as AnyToken).call(reader, token, ...target, at, context);
	return (value ?? spec.initial) as JsonValue;
}

/** The document's draft in `tx`, created from its initial value when absent. */
export async function draftOf(tx: Tx, args: Args): Promise<Record<string, unknown>> {
	const spec = args.doc as DocSpec;
	return (tx.doc as AnyToken).call(tx, docToken(spec), ...address(spec, ownerOf(args), args.key ?? undefined, true, args.seed));
}

export async function retireDoc(tx: Tx, args: Args): Promise<void> {
	const spec = args.doc as DocSpec;
	await (tx.retireDoc as AnyToken).call(tx, docToken(spec), ...address(spec, ownerOf(args), args.key ?? undefined, false));
}

export function watchArguments(args: Args): unknown[] {
	const spec = args.doc as DocSpec;
	return [docToken(spec), ...address(spec, ownerOf(args), args.key ?? undefined, false)];
}

/**
 * Makes `draft` equal to `next` with the smallest set of edits, so each commit stores a small delta instead of the whole
 * value: unchanged subtrees are left alone, objects and same-length arrays are patched in place.
 */
export function applyDeep(draft: Record<string, unknown> | unknown[], next: Record<string, unknown> | unknown[]): void {
	if (Array.isArray(draft) && Array.isArray(next)) {
		if (draft.length > next.length) draft.splice(next.length);
		next.forEach((value, index) => {
			if (index < draft.length) assign(draft, index, value);
			else draft.push(value);
		});
		return;
	}
	const target = draft as Record<string, unknown>;
	const source = next as Record<string, unknown>;
	for (const key of Object.keys(target)) if (!(key in source)) delete target[key];
	for (const [key, value] of Object.entries(source)) assign(target, key, value);
}

function assign(container: Record<string, unknown> | unknown[], key: string | number, value: unknown): void {
	const current = (container as Record<string | number, unknown>)[key];
	if (JSON.stringify(current) === JSON.stringify(value)) return;
	const bothArrays = Array.isArray(current) && Array.isArray(value);
	const bothObjects =
		typeof current === "object" && current !== null && !Array.isArray(current) && typeof value === "object" && value !== null && !Array.isArray(value);
	if (bothArrays || bothObjects) {
		applyDeep(current as Record<string, unknown>, value as Record<string, unknown>);
	} else {
		(container as Record<string | number, unknown>)[key] = value;
	}
}
