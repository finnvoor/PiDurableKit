import { type Context, type JsonValue } from "@earendil-works/chord";
import type { Models } from "@earendil-works/pi-ai";
import type { ExecutionEnv } from "../env/index.ts";
import type { SessionImpl } from "../session/session.ts";
import type { Transaction } from "../session/transaction.ts";
import type { Timers } from "../timers.ts";
import type { ConversationId, ReportInfo, Storage, StorageWrite, TaskId, TaskOutcome, TaskRecord, TaskState } from "../types.ts";
import type { Agent, ConversationHandle, HarnessInspection, HarnessOptions, RegistryReader, RegistrySnapshot, Settings, SettledTask, TaskInspection, Wake } from "./types.ts";
type AnyTaskRecord = TaskRecord<JsonValue, JsonValue, JsonValue>;
/** What `blockedReason()` reads of a task: the task graph keeps only this of each record. */
export type BlockedSubject = Pick<AnyTaskRecord, "id" | "kind" | "version" | "abortRequested" | "abortReason" | "restarts"> & {
    readonly status: TaskState<JsonValue, JsonValue>["status"];
};
/** The part of a record `blockedReason()` reads. */
export declare function blockedSubject(record: AnyTaskRecord): BlockedSubject;
/**
 * Why a task cannot be reserved: no registered definition can take it, or it was cut off `restartLimit` times in a row.
 * Derived from the registry, the settings, and the record's `restarts`.
 */
export type BlockedReason = "missing_task" | "task_too_old" | "migration_failed" | "restart_limit";
/** Terminal outcomes the scheduler writes without running task code. */
export type SchedulerOutcome = Extract<TaskOutcome<JsonValue>, {
    readonly status: "faulted" | "orphaned";
}>;
/** An invocation a conversation handle is bound to: its signal, and a check that throws once it ended. */
export type InvocationBinding = {
    readonly signal: AbortSignal;
    check(): void;
};
export type TaskSchedulerOptions = {
    readonly telemetry?: HarnessOptions["telemetry"];
    readonly session: SessionImpl;
    readonly storage: Storage;
    readonly registry: RegistryReader;
    /** The host's current model access (`HarnessOptions.models`); read at each access. */
    readonly models: () => Models;
    /** Resolve a conversation's agent against a snapshot; the runtime calls it at most once per phase. */
    readonly agent: (conversationId: ConversationId, snapshot: RegistrySnapshot, context: Context) => Promise<Agent>;
    /** Resolve the settings; read at each access. */
    readonly settings: () => Settings;
    /** Build a conversation's environment with `HarnessOptions.env`. */
    readonly env: (conversationId: ConversationId, context: Context) => Promise<ExecutionEnv | undefined>;
    readonly now: () => number;
    /** `HarnessOptions.onWake`: replaces the timer for sleeping tasks. */
    readonly onWake: ((wake: Wake) => void) | undefined;
    /** The host's timers (`HarnessOptions.setTimer`). */
    readonly timers: Timers;
    /** While closing, on the line after admitted commits settle, write what the callback returns straight to Storage. */
    readonly writeAtClose: (writes: () => readonly StorageWrite[]) => Promise<void>;
    readonly report: (error: unknown, info: ReportInfo, context?: Context) => void;
    /** Harness cleanup staged in the commit that makes an outcome the scheduler wrote itself terminal. */
    readonly settleOutcome: (tx: Transaction, record: AnyTaskRecord, outcome: SchedulerOutcome) => Promise<void>;
    /** Withdraw a conversation's queued inputs, for conversation abort and abort cascades. */
    readonly withdrawInputs: (tx: Transaction, conversationId: ConversationId) => Promise<void>;
    /** Invocation-bound handle of an existing conversation, for task runtimes and tools. */
    readonly conversation: (id: ConversationId, binding: InvocationBinding, context: Context) => Promise<ConversationHandle | undefined>;
    /** Context for scheduler commits and invocations; carries no caller cancellation. */
    readonly context: Context;
};
/**
 * Durable task scheduler of one Harness.
 *
 * `#live` mirrors every committed non-terminal task record: pending, running, waiting, sleeping, and completing. The
 * synchronous commit listener updates it on the Session line, so code running on the line reads exactly the committed
 * state from it.
 *
 * Tasks and conversations form one ownership tree (spec §5.5): a task's parent is its owner task, or its conversation;
 * a conversation's parent is its owner task, if any. Walks up that tree decide what reaches one task: a cancelling
 * owner, a scope. `#below` lists the tree downward around live work, so what lies below one node is a walk down from
 * it: a task's live ordinary owned work, which holds its outcome as `completing` and delays its abort handler, a
 * scope's tasks, a cascade's reach. No pass visits every live task; the sets below hold each pass's candidates.
 *
 * The ownership indexes are bounded by live work: an owner edge and an ended task's ownership fields are kept only while
 * something is listed below them in `#below`, so only the chains above live tasks are known, whole. Work that appears
 * later below a dropped node finds it unknown and loads its chain from storage again.
 *
 * Invariant: every task transition is decided and written by one callback serialized on the Session line. That covers
 * reservation, marks, runtime commits, finalization, and the synchronous step before each phase, which applies the
 * precedence rules and writes a fault or handover. Handlers and joins run off the line. An invocation ends inside the
 * step that decides its end, so a runtime commit it queued either lands before that decision or is rejected.
 */
export declare class TaskScheduler {
    #private;
    constructor(options: TaskSchedulerOptions);
    /**
     * Load live tasks and change surviving `running` tasks back to `pending`, counting the restart. Dispatches nothing. A
     * task that reaches the restart limit this way is parked and reported.
     */
    open(context: Context): Promise<void>;
    /**
     * Enable scheduling, and make sleeping tasks that are due runnable: a host wakeup, such as an alarm, calls this.
     * Idempotent; the kick does nothing once closing.
     */
    resume(): void;
    /**
     * Run a task parked by the restart limit again: clears its restart count and enables scheduling. Does nothing for a
     * task that is not parked; rejects for an unknown one.
     */
    retry(id: TaskId, context: Context): Promise<void>;
    /**
     * Why a live task cannot run here, if it cannot: its definition (missing, too old, failed migration) or the restart
     * limit. A running task, an abort-marked one, and one holding its outcome are never blocked.
     */
    blockedReason(record: BlockedSubject): BlockedReason | undefined;
    /** Call `listener` when blocked reasons may have changed without a commit: a registry change or a failed migration. */
    subscribeBlocked(listener: () => void): () => void;
    /**
     * When the Session next needs a process: `active` while some task can run now or is running, `at` for the earliest
     * sleep not yet due. Synchronous, from memory; a task whose chain is not loaded yet counts as it would alone.
     */
    wake(): Wake;
    /**
     * Signal every invocation and wait for them, then write the tasks they ran back as `pending` (`writeAtClose`), as a
     * close is not a crash. Close calls this after every close listener has run, so waits, watches, and streams a task
     * holds end with the Session's reason, not as cancelled by its signal.
     */
    join(): Promise<void>;
    /**
     * Commit the abort mark, or settle a task that no registered definition can take as `orphaned` when nothing it owns
     * is live, then join the run invocation seen on the line; the commit listener signalled it. The abort invocation
     * starts once the task's ordinary owned work is gone. A `completing` task is only marked. A request replaces a
     * `restart` mark, so a task abandoned after a restart that waits for its definition is orphaned; with `keepRestart`,
     * as for an owner's own cleanup, such a task keeps its mark and waits on.
     */
    abort(id: TaskId, context: Context, keepRestart?: boolean): Promise<"marked" | "terminal">;
    waitForTask(id: TaskId, context: Context): Promise<SettledTask<JsonValue>>;
    /**
     * Resolve when ordinary traversal from the conversation, or from every ownerless conversation, reaches no live
     * non-background task.
     */
    waitForIdle(conversationId: ConversationId | undefined, context: Context): Promise<void>;
    /**
     * `Conversation.abort()`: in one commit, withdraw the queued inputs and mark every live non-background task that
     * ordinary traversal from the conversation reaches; resolves once the scope is idle. With `background`, traversal
     * crosses background boundaries, and the wait also covers every task it reached.
     */
    abortConversation(conversationId: ConversationId, background: boolean, context: Context): Promise<void>;
    /** Sizes of the ownership indexes, for tests that bound the scheduler's memory. */
    get indexSizes(): Readonly<Record<"live" | "settled" | "edges" | "below" | "roots" | "unloaded" | "dropQueue", number>>;
    /**
     * Scheduling state and every live task with its derived state, read on the Session line. Runs no task code: a
     * pending migration shows as `ready` with `migrates`, and only a migration the scheduler already tried, or one that
     * cannot exist, shows as failed.
     */
    inspect(snapshot: RegistrySnapshot): Promise<{
        scheduling: HarnessInspection["scheduling"];
        tasks: TaskInspection[];
    }>;
}
export {};
