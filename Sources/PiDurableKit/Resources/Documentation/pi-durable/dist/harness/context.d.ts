import type { Context } from "@earendil-works/chord";
import type { Message } from "@earendil-works/pi-ai";
import type { SessionImpl } from "../session/session.ts";
import type { ConversationId, EntryId, EntryRecord, Storage } from "../types.ts";
import type { ContextView } from "./types.ts";
/** Head marker and newest visible entry that fix one committed context range. */
export type ContextBounds = {
    readonly head: (EntryRecord & {
        readonly head: EntryId;
    }) | undefined;
    readonly tail: EntryId;
};
/**
 * Capture the bounds of the current context, or of the context cut off at the visible entry `at`, with two O(1)
 * reads. Run this on the Session line; entries at or below the tail are immutable, so `deriveContext()` can then scan
 * them off the line.
 */
export declare function captureContextBounds(storage: Storage, conversationId: ConversationId, context: Context, at?: EntryId): Promise<ContextBounds | undefined>;
/**
 * One context read: the visible entries it scanned, from the head marker's head, or transcript start, through
 * `bounds.tail`, oldest first, and the view derived from them. Entries at or below the tail never change, so a later
 * read with the same head marker extends both.
 */
export type ContextRange = {
    readonly bounds: ContextBounds;
    readonly entries: readonly EntryRecord[];
    readonly view: ContextView;
    /** Targets of the edits in `entries`. */
    readonly edited: ReadonlySet<EntryId>;
    /**
     * `view.messages` from the contributed messages before the last assistant message. Tool results are ordered within
     * the messages up to the next assistant message, so later entries cannot change these.
     */
    readonly settled: readonly Message[];
    /** Contributed messages from the last assistant message on, before tool result ordering. */
    readonly open: readonly Message[];
};
/**
 * `readContext()` that reuses `previous`, an earlier range of the same conversation: with the same head marker, only
 * entries after its tail are scanned. Returns the view and the range to pass to the next read. A range outlives the
 * read, so its entries are frozen like `MemoryStorage` records, and the returned view has its own arrays.
 */
export declare function readContextFrom(session: SessionImpl, storage: Storage, conversationId: ConversationId, context: Context, at: EntryId | undefined, previous: ContextRange | undefined): Promise<{
    readonly view: ContextView;
    readonly range: ContextRange | undefined;
}>;
/** Committed context of one conversation: bounds captured on the Session line, entries derived off it. */
export declare function readContext(session: SessionImpl, storage: Storage, conversationId: ConversationId, context: Context, at?: EntryId): Promise<ContextView>;
/**
 * Derive the active transcript and model context of one conversation within captured bounds.
 *
 * H = newest visible head marker; the range runs from `H.head` (or transcript start) through the tail. Per target,
 * the newest edit in the range wins. Context entries are H followed by the range's non-head entries.
 */
export declare function deriveContext(storage: Storage, conversationId: ConversationId, bounds: ContextBounds | undefined, context: Context): Promise<ContextView>;
/** The raw active entries within captured bounds, without deriving model context. */
export declare function activeEntries(storage: Storage, conversationId: ConversationId, bounds: ContextBounds | undefined, context: Context): Promise<readonly EntryRecord[]>;
/**
 * Place each assistant's tool results directly after it in call order. Results are taken from the messages before
 * the next assistant; a missing result is synthesized and unmatched results are dropped.
 */
export declare function orderToolResults(messages: readonly Message[]): Message[];
