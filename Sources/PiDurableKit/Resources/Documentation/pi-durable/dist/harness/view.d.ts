import { type AttachedReplicatedState, type Context } from "@earendil-works/chord";
import { type Op } from "@earendil-works/chord/delta";
import type { SessionImpl } from "../session/session.ts";
import type { CommitPublication, ConversationId, ConversationRecord, EntryRecord, JsonObject, Storage, WatchHandle } from "../types.ts";
/** Structural mount of one conversation's active transcript and built-in documents (spec §9.3). */
export type ConversationView = {
    readonly conversation: ConversationRecord;
    /** Raw active entries, as `ContextView.entries`: the head marker, then the non-head entries from its head. */
    readonly entries: readonly EntryRecord[];
    /** Built-in conversation documents keyed by kind; absent documents are absent. */
    readonly docs: Readonly<Record<string, JsonObject>>;
};
/** Receives each next revision of a mount, and the Session's close. */
export type ViewObserver = {
    advance?(value: ConversationView, ops: readonly Op[], context: Context): void;
    /** Every publication, after the mount took it; `ops` are the mount's, possibly none. */
    publication?(before: ConversationView, after: ConversationView, ops: readonly Op[], publication: CommitPublication, context: Context): void;
    closeSession(): void;
};
/** The view mounts of a Harness, for adapters built on them. */
export declare function conversationViews(harness: object): ConversationViews;
/**
 * The Harness's conversation view mounts: at most one per conversation, built on the Session line by its first
 * observer and dropped with its last. Each mount advances from the Session's commit publications, which are durable.
 */
export declare class ConversationViews {
    #private;
    constructor(session: SessionImpl, storage: Storage);
    /** A disposable read-only Chord state of the view. */
    state(id: ConversationId, context: Context): Promise<AttachedReplicatedState<ConversationView>>;
    /** A serialized exact-frame watch of the view; cancelling `context` stops it. */
    watch(id: ConversationId, context: Context): Promise<WatchHandle<ConversationView>>;
    /**
     * Register an observer created from the current revision, atomically on the Session line: it sees every later
     * publication and nothing earlier. `create` may read committed Storage, still on the line. `release` drops it, and
     * the mount with its last observer.
     */
    attach<O extends ViewObserver>(id: ConversationId, create: (value: ConversationView, release: () => void, storage: Storage) => O | Promise<O>, context: Context): Promise<{
        observer: O;
        detach: () => void;
    }>;
}
