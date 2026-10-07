import { type Context, type JsonValue } from "@earendil-works/chord";
import type { Models } from "@earendil-works/pi-ai";
import type { ExecutionEnv } from "../env/index.ts";
import type { SessionImpl } from "../session/session.ts";
import type { Transaction } from "../session/transaction.ts";
import type { ConversationId, Storage, TaskId, TaskOutcome, TaskRecord } from "../types.ts";
import type { Agent, ConversationHandle, HarnessInspection, RegistryReader, RegistrySnapshot, Settings, SettledTask, TaskInspection } from "./types.ts";
type AnyTaskRecord = TaskRecord<JsonValue, JsonValue, JsonValue>;
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
    readonly session: SessionImpl;
    readonly storage: Storage;
    readonly registry: RegistryReader;
    readonly models: Models;
    /** Resolve a conversation's agent against a snapshot; the runtime calls it at most once per phase. */
    readonly agent: (conversationId: ConversationId, snapshot: RegistrySnapshot, context: Context) => Promise<Agent>;
    /** Resolve the settings; read at each access. */
    readonly settings: () => Settings;
    /** Build a conversation's environment with `HarnessOptions.env`. */
    readonly env: (conversationId: ConversationId, context: Context) => Promise<ExecutionEnv | undefined>;
    readonly now: () => number;
    readonly report: (error: unknown) => void;
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
 * `#live` mirrors every committed non-terminal task record: pending, running, waiting, and completing. The synchronous
 * commit listener updates it on the Session line, so code running on the line reads exactly the committed state from it.
 *
 * Tasks and conversations form one ownership tree (spec §5.5): a task's parent is its owner task, or its conversation;
 * a conversation's parent is its owner task, if any. Walks up that tree decide cascades, idle scopes, and whether a
 * task's ordinary owned work is live, which holds its outcome as `completing` and delays its abort handler.
 *
 * Invariant: every task transition is decided and written by one callback serialized on the Session line. That covers
 * reservation, marks, runtime commits, finalization, and the synchronous step before each phase, which applies the
 * precedence rules and writes a fault or handover. Handlers and joins run off the line. An invocation ends inside the
 * step that decides its end, so a runtime commit it queued either lands before that decision or is rejected.
 */
export declare class TaskScheduler {
    #private;
    constructor(options: TaskSchedulerOptions);
    /** Load live tasks and change surviving `running` tasks back to `pending`. Dispatches nothing. */
    open(context: Context): Promise<void>;
    /** Enable scheduling. Idempotent; the kick does nothing once closing. */
    resume(): void;
    /** Wait for every invocation signalled by `#seal()`. Writes nothing. */
    join(): Promise<void>;
    /**
     * Commit the abort mark, or settle a task that no registered definition can take as `orphaned` when nothing it owns
     * is live, then join the run invocation seen on the line; the commit listener signalled it. The abort invocation
     * starts once the task's ordinary owned work is gone. A `completing` task is only marked.
     */
    abort(id: TaskId, context: Context): Promise<"marked" | "terminal">;
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
