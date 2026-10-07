import { type Context, type Draft, type JsonValue } from "@earendil-works/chord";
import { type Tracker } from "@earendil-works/chord/delta";
import { type AnyDocDefinition } from "../documents.ts";
import type { ConversationDocFamilyToken, ConversationDocToken, ConversationId, ConversationOwnership, ConversationQuery, ConversationRecord, Cursor, DocumentAddress, DocumentCommitChange, DocumentId, DocumentRecord, Entry, EntryDraft, EntryId, EntryQuery, EntryRecord, JsonObject, Seq, SessionDocFamilyToken, SessionDocToken, Storage, StorageWrite, SubmissionCreate, SubmissionId, SubmissionRecord, SubmissionSettlement, Task, TaskDocFamilyToken, TaskDocToken, TaskId, TaskOptions, TaskQuery, TaskRecord, Tx, TypedEntry, TypedEntryDraft } from "../types.ts";
type AnyTaskRecord = TaskRecord<JsonValue, JsonValue, JsonValue>;
/** One committed document incarnation owned by the Session tracker cache. */
export type LoadedDocument = {
    readonly addressId: string;
    readonly record: DocumentRecord;
    /** Persisted definition version; older while the tracked value is migrated only in memory. */
    storedVersion: number;
    /** Definition version whose shape the tracked value has; access with another version reloads from Storage. */
    readonly valueVersion: number;
    /** Stored deltas after the newest base; advanced by adoption so the next predicate call needs no read. */
    deltasSinceBase: number;
    readonly tracker: Tracker<JsonObject>;
};
/** Session services used by a transaction while it holds the mutation line. */
export interface TransactionHost {
    readonly storage: Storage;
    /** Wall clock for task lifecycle times. */
    now(): number;
    /** Return the cached current incarnation without loading. */
    cached(addressId: string): LoadedDocument | undefined;
    /** Return the cached current incarnation, cold-loading and migrating it when necessary. */
    load(definition: AnyDocDefinition, addressId: string, address: DocumentAddress, context: Context): Promise<LoadedDocument | undefined>;
    /** Install a newly committed incarnation. */
    install(document: LoadedDocument): void;
    /** Remove a retired incarnation if it is still the cached occupant of its address. */
    evict(addressId: string, recordId: DocumentId): void;
    /** Stage writes that belong to every newly created or forked conversation, in its creating transaction. */
    conversationCreated(tx: Transaction, record: ConversationRecord): Promise<void>;
}
/** Defaults a commit binds to: `tx.createTask()` conversation and the task attributed to appended entries. */
export type TransactionScope = {
    readonly conversationId?: ConversationId;
    /** Task whose runtime commit this is; stamped as `byTaskId` on appended entries. */
    readonly taskId?: TaskId;
};
/**
 * Transaction for one Session commit callback.
 *
 * Every asynchronous operation is tracked so callback settlement can reject and drain unfinished work. Session calls
 * one settlement method, then either discards prepared changes or adopts them once after Storage succeeds.
 */
export declare class Transaction implements Tx {
    #private;
    constructor(host: TransactionHost, context: Context, scope?: TransactionScope);
    conversation(id: ConversationId): Promise<ConversationRecord | undefined>;
    entry(id: EntryId): Promise<EntryRecord | undefined>;
    entry<D extends JsonValue>(token: Entry<D>, id: EntryId): Promise<TypedEntry<D> | undefined>;
    task(id: TaskId): Promise<AnyTaskRecord | undefined>;
    scanConversations(query: ConversationQuery, limit: number, cursor?: Cursor): Promise<import("../types.ts").Page<ConversationRecord, Readonly<Record<string, JsonValue>>>>;
    scanEntries(query: EntryQuery, limit: number, cursor?: Cursor): Promise<import("../types.ts").Page<EntryRecord, Readonly<Record<string, JsonValue>>>>;
    latestHeadMarker(conversationId: ConversationId): Promise<(EntryRecord & {
        readonly head: EntryId;
    }) | undefined>;
    scanTasks(query: TaskQuery, limit: number, cursor?: Cursor): Promise<import("../types.ts").Page<TaskRecord<JsonValue, JsonValue, JsonValue>, Readonly<Record<string, JsonValue>>>>;
    /** Internal: committed submission record. */
    submission(id: SubmissionId): Promise<SubmissionRecord | undefined>;
    /** Committed submission with a conversation-scoped request ID. */
    submissionByRequest(conversationId: ConversationId, requestId: string): Promise<SubmissionRecord | undefined>;
    createConversation(options: {
        readonly ownership: ConversationOwnership;
    }): Promise<ConversationRecord>;
    /** Internal final-form bootstrap path for the reserved root identity. */
    createRootConversation(): Promise<ConversationRecord>;
    forkConversation(parentConversationId: ConversationId, at: EntryId, options: {
        readonly ownership: ConversationOwnership;
    }): Promise<ConversationRecord>;
    appendEntry(conversationId: ConversationId, value: EntryDraft): Promise<EntryRecord>;
    appendEntry<D extends JsonValue>(token: Entry<D>, conversationId: ConversationId, value: TypedEntryDraft<NoInfer<D>>): Promise<TypedEntry<D>>;
    createTask<I, S extends {
        phase: string;
    }, R, H extends object>(task: Task<I, S, R, H>, input: I, options: TaskOptions): Promise<TaskId<R>>;
    /** Create a raw submission record with a fresh ID; no admission rules apply. */
    createSubmission(create: SubmissionCreate): Promise<SubmissionRecord>;
    /**
     * Settle a submission. Resolved during assembly against the transaction's latest candidate record, falling back to
     * committed state, so it is not a caller table read and works after the first table write.
     */
    settleSubmission(id: SubmissionId, settlement: SubmissionSettlement): void;
    /** Place a queued submission at `entry`; resolved during assembly like `settleSubmission()`. */
    placeSubmission(id: SubmissionId, entry: EntryId): void;
    /** Internal: replace one task record completely. Tasks change their own state through their runtime. */
    setTask(value: AnyTaskRecord): void;
    /** Internal: candidate records of the tasks this transaction created or replaced so far. */
    stagedTasks(): AnyTaskRecord[];
    /** Internal: conversations this transaction created or forked so far. */
    stagedConversations(): ConversationRecord[];
    doc<T extends JsonObject>(token: SessionDocToken<T>): Promise<Draft<T>>;
    doc<T extends JsonObject>(token: ConversationDocToken<T>, conversationId: ConversationId): Promise<Draft<T>>;
    doc<T extends JsonObject>(token: TaskDocToken<T>, taskId: TaskId): Promise<Draft<T>>;
    doc<T extends JsonObject, I extends JsonValue>(token: SessionDocFamilyToken<T, I>, key: string, seed: I): Promise<Draft<T>>;
    doc<T extends JsonObject, I extends JsonValue>(token: ConversationDocFamilyToken<T, I>, conversationId: ConversationId, key: string, seed: I): Promise<Draft<T>>;
    doc<T extends JsonObject, I extends JsonValue>(token: TaskDocFamilyToken<T, I>, taskId: TaskId, key: string, seed: I): Promise<Draft<T>>;
    retireDoc<T extends JsonObject>(token: SessionDocToken<T>): Promise<void>;
    retireDoc<T extends JsonObject>(token: ConversationDocToken<T>, conversationId: ConversationId): Promise<void>;
    retireDoc<T extends JsonObject>(token: TaskDocToken<T>, taskId: TaskId): Promise<void>;
    retireDoc<T extends JsonObject, I extends JsonValue>(token: SessionDocFamilyToken<T, I>, key: string): Promise<void>;
    retireDoc<T extends JsonObject, I extends JsonValue>(token: ConversationDocFamilyToken<T, I>, conversationId: ConversationId, key: string): Promise<void>;
    retireDoc<T extends JsonObject, I extends JsonValue>(token: TaskDocFamilyToken<T, I>, taskId: TaskId, key: string): Promise<void>;
    /** Seal after callback failure: abort every change and observe every pending operation. */
    settleFailure(): Promise<void>;
    /**
     * Seal after callback success, prepare every open change, and assemble the atomic batch.
     * Any failure aborts every change before Storage admission.
     */
    settleSuccess(): Promise<readonly StorageWrite[]>;
    /** Abort every prepared change after Storage failure or when no write is required. */
    discard(): void;
    /** Adopt every prepared change by pointer swap after Storage success and describe the publication. */
    adopt(seq: Seq): DocumentCommitChange[];
}
export {};
