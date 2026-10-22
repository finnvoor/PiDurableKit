import { type AttachedReplicatedState, type Context, type JsonValue } from "@earendil-works/chord";
import { type SessionImpl } from "../session/session.ts";
import type { ConversationId, JoinPolicy, Storage, TaskId, TaskOutcome, WatchHandle } from "../types.ts";
import { type BlockedReason, type BlockedSubject } from "./scheduler.ts";
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
/** Asleep until the Harness clock reaches `until`. */
 | {
    readonly status: "sleeping";
    readonly phase: string;
    readonly until: number;
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
    /**
     * Why it cannot run here, when it cannot: no registered definition takes it (`missing_task`, `task_too_old`,
     * `migration_failed`), or the restart limit parked it (`restart_limit`). Follows registry changes.
     */
    readonly blocked?: BlockedReason;
    /** Conversations this task owns, in ID order. */
    readonly conversations: readonly ConversationId[];
};
/** Every live task of the Session (spec §9.5). */
export type TaskGraph = {
    /** Every live task, keyed by its decimal ID. */
    readonly tasks: Readonly<Record<string, TaskGraphNode>>;
};
export type TaskGraphWatch = WatchHandle<TaskGraph>;
/** What the graph asks the scheduler: a task's blocked reason, and when reasons may change without a commit. */
export type TaskGraphBlocking = {
    readonly blocked: (record: BlockedSubject) => BlockedReason | undefined;
    readonly subscribeBlocked: (listener: () => void) => () => void;
};
/**
 * The Harness's task graph mount: built on the Session line by its first observer and dropped with its last. It
 * advances from the Session's commit publications, which are durable.
 */
export declare class TaskGraphView {
    #private;
    constructor(session: SessionImpl, storage: Storage, blocking: TaskGraphBlocking);
    /** A disposable read-only Chord state of the graph. */
    state(context: Context): Promise<AttachedReplicatedState<TaskGraph>>;
    /** A serialized exact-frame watch of the graph; cancelling `context` stops it. */
    watch(context: Context): Promise<TaskGraphWatch>;
}
