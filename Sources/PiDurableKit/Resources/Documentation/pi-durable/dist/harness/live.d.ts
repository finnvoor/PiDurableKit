import type { Draft, JsonRepresentation, JsonValue } from "@earendil-works/chord";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { Transaction } from "../session/transaction.ts";
import type { EntryId, SubmissionId, SubmissionSettlement, TaskId, TaskRecord, Tx } from "../types.ts";
import type { SchedulerOutcome } from "./scheduler.ts";
import type { CompactionReason, CompactionResult, ToolDiagnostic } from "./types.ts";
/** Presentation of one tool call of the current round. */
export type ToolSlot = {
    callId: string;
    name: string;
    /**
     * Absent for a call not started yet (sequential round) and for a call its request did not offer, which starts `done`
     * with the `entry` generation wrote.
     */
    taskId?: TaskId;
    status: "pending" | "running" | "done";
    /** Retained running output and what the bounds dropped. */
    output?: string;
    droppedBytes?: number;
    droppedLines?: number;
    /** Last `details()` value. */
    details?: JsonValue;
    /** Diagnostics recorded through `api.diagnostic()`. */
    diagnostics?: ToolDiagnostic[];
    /** Result entry once done; absent when the tool task faulted or was orphaned. */
    entry?: EntryId;
};
/** Presentation of one live compaction task (spec §8.7). */
export type CompactionStatus = {
    taskId: TaskId<CompactionResult>;
    reason: CompactionReason;
    /** Whether a generation waits for it: a compaction the generation owns. */
    blocking: boolean;
    attempt: number;
    /** Durable backoff before the next summarization attempt. */
    retry?: {
        at: number;
        error: string;
    };
};
/** Built-in live conversation state: run control and presentation of the current generation and tool round. */
export type LiveState = {
    /** Run control: the task that settles the run's inputs, and those inputs; present exactly while busy. */
    run?: {
        taskId: TaskId;
        inputs: SubmissionId[];
    };
    /** Presentation of the current generation attempt. */
    generation?: {
        attempt: number;
        /** Committed throttled partial of the in-flight response. */
        message?: JsonRepresentation<AssistantMessage>;
        /** Durable backoff before the next attempt. */
        retry?: {
            at: number;
            error: string;
        };
        /** Provider-side deferred response being polled. */
        deferred?: {
            pollAt: number;
        };
    };
    /** The current tool round in call order, from the tool-calling answer until the generation's `tools` phase ends it. */
    tools?: ToolSlot[];
    /** Live compaction tasks in task ID order; absent when none. */
    compactions?: CompactionStatus[];
};
export declare const LiveDoc: import("../types.ts").ConversationDocToken<LiveState>;
/**
 * End the run owned by `taskId`: settle each of its inputs and remove `run`. Always removes `generation` and `tools`,
 * whose presentation belongs to the ending run.
 */
export declare function endRun(tx: Tx, live: Draft<LiveState>, taskId: TaskId, settlement: SubmissionSettlement): void;
/** Add the status of a compaction task created in this commit; statuses stay in task ID order. */
export declare function addCompactionStatus(live: Draft<LiveState>, status: CompactionStatus): void;
/** The status of compaction task `taskId`, if listed. */
export declare function compactionStatus(live: Draft<LiveState>, taskId: TaskId): Draft<CompactionStatus> | undefined;
/** Remove the status of compaction task `taskId`, and the list once empty. */
export declare function removeCompactionStatus(live: Draft<LiveState>, taskId: TaskId): void;
/** The slot of tool task `taskId` in the current round, if the round still lists it. */
export declare function toolSlot(live: Draft<LiveState>, taskId: TaskId): Draft<ToolSlot> | undefined;
/** Mark a slot done: the result entry, if any, now carries its running output, details, and diagnostics. */
export declare function finishSlot(slot: Draft<ToolSlot>, entry: EntryId | undefined): void;
/** Remove what a tool published while running; its result entry or a rerun replaces it. */
export declare function clearProgress(slot: Draft<ToolSlot>): void;
/**
 * Harness cleanup for a terminal outcome the scheduler writes itself (`faulted` or `orphaned`). A run task ends its
 * run; a tool task's slot is marked done without an entry, and context derivation synthesizes the missing result; a
 * compaction task's status is removed.
 * Ignores other kinds so it never creates `pi.live` elsewhere. The scheduler calls this without knowing task kinds;
 * the Harness passes it in (spec §5.4).
 * REMINDER: a committed generation partial becomes an aborted assistant entry here, exactly as in the generation abort
 * handler, so the transcript keeps what the model produced and `pi.usage` counts its spend. The scheduler's commit has
 * no task scope, so that entry has no `byTaskId`. Faults come from task bugs
 * or malformed provider data (a non-JSON value in a response), or a commit the Storage rejected without effect; an
 * uncertain storage failure poisons the Session instead and writes no outcome.
 */
export declare function settleSchedulerOutcome(tx: Transaction, record: TaskRecord<JsonValue, JsonValue, JsonValue>, outcome: SchedulerOutcome): Promise<void>;
