import type { Draft, JsonRepresentation } from "@earendil-works/chord";
import type { ConversationId, EntryDraft, EntryId, JsonObject, SubmissionId, Tx } from "../types.ts";
import type { QueueMode, Settings, UserInput } from "./types.ts";
/** A queued submission: user input for a run, or a passive entry write. */
export type InboxItem = {
    id: SubmissionId;
    mode: "steer" | "followUp";
    content: JsonRepresentation<UserInput>;
}
/** `entry` is an `EntryDraft`, stored as plain JSON. */
 | {
    id: SubmissionId;
    mode: "write";
    entry: JsonObject;
};
/** Built-in queue of one conversation's submissions waiting for a boundary, in ID order. */
export type InboxState = {
    items: InboxItem[];
};
export declare const InboxDoc: import("../types.ts").ConversationDocToken<InboxState>;
/** The settings a boundary reads, on the Session line. */
export type QueueModes = Pick<Settings, "steeringMode" | "followUpMode">;
/** What a boundary reads before the commit's first table write, and the newest head it has seen so far. */
export type Boundary = {
    readonly conversationId: ConversationId;
    readonly inbox: Draft<InboxState>;
    readonly steeringMode: QueueMode;
    readonly followUpMode: QueueMode;
    /** Start of the active range, the newest head marker's `head`; advanced by heads written in this commit. */
    head: EntryId | undefined;
};
/** Selected user items, in ID order, and whether a `head: "self"` write (a reset) was placed. */
export type BoundaryResult = {
    readonly users: SubmissionId[];
    readonly reset: boolean;
};
/**
 * Read what a boundary needs. Table reads must precede the commit's first table write, so callers prepare the
 * boundary at the start of their commit.
 */
export declare function prepareBoundary(tx: Tx, conversationId: ConversationId, modes: QueueModes): Promise<Boundary>;
/**
 * Place the queued items a boundary selects (spec §6): every write, the first or all steers, and at `final` the first
 * or all follow-ups. A selected reset turns a `postTools` boundary into `final`. Writes are placed first and user
 * items after them, each in ID order, so user items queued before a reset run in the new context. A write whose head
 * targets an entry before the active range, including a range started earlier in this commit, is stale. Selected and
 * stale items are removed positionally.
 */
export declare function applyBoundary(tx: Tx, boundary: Boundary, at: "postTools" | "final", now: number): Promise<BoundaryResult>;
/** Whether a head write targets an entry before the active range, so placing it would bring back cut history. */
export declare function isStale(boundary: Boundary, entry: EntryDraft): boolean;
/** Remove a withdrawn submission's item; the caller settles the submission. */
export declare function removeInboxItem(tx: Tx, conversationId: ConversationId, id: SubmissionId): Promise<void>;
/**
 * Withdraw every queued input of a conversation, as `Conversation.abort()` and abort cascades do: each settles
 * `unanswered` with `aborted` and leaves the inbox; queued writes stay for later placement.
 */
export declare function withdrawQueuedInputs(tx: Tx, conversationId: ConversationId): Promise<void>;
