import { type AttachedReplicatedState, type Context, type JsonValue } from "@earendil-works/chord";
import type { SessionImpl } from "../session/session.ts";
import type { ConversationId, JoinPolicy, Storage, TaskId, TaskOutcome, WatchHandle } from "../types.ts";
/** A live task's durable status without its checkpoint and outcome payloads (spec §9.5). */
export type TaskGraphState = {
    readonly status: "pending" | "running";
    readonly phase: string;
} | {
    readonly status: "waiting";
    readonly phase: string;
    readonly on: readonly TaskId[];
    readonly policy: JoinPolicy;
}
/** Outcome held until its ordinary owned work drains. */
 | {
    readonly status: "completing";
    readonly outcome: TaskOutcome<JsonValue>["status"];
};
export type TaskGraphNode = {
    readonly id: TaskId;
    readonly kind: string;
    readonly conversationId: ConversationId;
    /** Owner task; absent for a conversation-owned task. */
    readonly owner?: TaskId;
    readonly background: boolean;
    readonly abortRequested: boolean;
    readonly state: TaskGraphState;
    /** Conversations this task owns, in ID order. */
    readonly conversations: readonly ConversationId[];
};
/** Every live task of the Session (spec §9.5). */
export type TaskGraph = {
    /** Every live task, keyed by its decimal ID. */
    readonly tasks: Readonly<Record<string, TaskGraphNode>>;
};
export type TaskGraphWatch = WatchHandle<TaskGraph>;
/**
 * The Harness's task graph mount: built on the Session line by its first observer and dropped with its last. It
 * advances from the Session's commit publications, which are durable.
 */
export declare class TaskGraphView {
    #private;
    constructor(session: SessionImpl, storage: Storage);
    /** A disposable read-only Chord state of the graph. */
    state(context: Context): Promise<AttachedReplicatedState<TaskGraph>>;
    /** A serialized exact-frame watch of the graph; cancelling `context` stops it. */
    watch(context: Context): Promise<TaskGraphWatch>;
}
