import { type Context, type JsonValue } from "@earendil-works/chord";
import type { CommitPublication, ConversationDocFamilyToken, ConversationDocToken, ConversationId, ConversationRecord, DocumentRecord, DocumentState, DocumentWatch, EntryId, JsonObject, ReportInfo, RewindableConversationDocFamilyToken, RewindableConversationDocToken, Session, SessionDocFamilyToken, SessionDocToken, SessionEnd, SetTimer, Storage, StorageWrite, TaskDocFamilyToken, TaskDocToken, TaskId, Tx } from "../types.ts";
import { Transaction, type TransactionScope } from "./transaction.ts";
/**
 * Open a Session kernel over one storage backend. `now` is the wall clock for task times; default `Date.now`.
 * `setTimer` arms the timers that evict idle documents; default `setTimeout` (see `HarnessOptions.setTimer`). The first
 * error a Storage method throws fails the Session (`SessionFailed`); see `SessionImpl`.
 */
export declare function createSession(storage: Storage, options?: {
    readonly now?: () => number;
    readonly documentRetentionMs?: number;
    readonly setTimer?: SetTimer;
}): Session;
/** Internal, for tests: the retention of every Session that keeps the default, as a suite run with eviction at once. */
export declare function setDefaultDocumentRetention(ms: number): void;
/**
 * A retention as given, when it is a number of milliseconds, `0` or more (`Infinity` keeps documents); otherwise the
 * default.
 */
export declare function documentRetention(ms: number | undefined): number;
/**
 * Session kernel: one mutation line, the loaded document tracker cache, and committed publication.
 *
 * The cache is bounded by use: a document with no watch or document state attached leaves it once it was not read or
 * written for the retention period, and the next access loads it from Storage. Eviction runs as a job on the mutation
 * line, so no transaction ever holds a tracker that leaves.
 *
 * Only committed state is observable. Every commit callback, preparation, Storage settlement, adoption, and
 * publication enqueue runs while the line is held; listeners run later.
 *
 * Storage failures are final. Every Storage call goes through one guard: the first error a Storage method throws, other
 * than for a cancelled caller, fails the Session, as does a commit it cannot adopt. That call gets the error; every later
 * call and every Storage call still underway gets `SessionFailed`; close listeners run at once with the error, and the
 * Session then closes itself, Storage included, and `closed` settles. Nothing retries: transient errors are the
 * Storage's to retry. Reopening recovers from what was committed.
 */
export declare class SessionImpl implements Session {
    #private;
    get closed(): Promise<SessionEnd>;
    /** Internal: the error that failed the Session, if one did. */
    get failure(): {
        readonly error: unknown;
    } | undefined;
    /** Internal: rejects with `SessionFailed` the moment the Session fails, before work underway has ended; never resolves. */
    get failed(): Promise<never>;
    constructor(storage: Storage, now?: () => number, documentRetentionMs?: () => number | undefined, setTimer?: SetTimer);
    /** The Storage behind the failure guard; every component reads and writes through it. */
    protected get storage(): Storage;
    commit<T>(change: (tx: Tx) => T | Promise<T>, context: Context): Promise<T>;
    /**
     * Internal: fail the Session with `error`, the first wins, and report it once. Admission ends, and close listeners run
     * now; they read the error from `failure`. The Storage guard calls this; the Harness also calls it for a throw in its
     * scheduler's own commits.
     */
    fail(error: unknown, context?: Context): void;
    /**
     * Internal commit exposing the concrete transaction and its internal operations, such as the reserved-ID root
     * bootstrap and task replacement. `scope` sets the default `tx.createTask()` conversation and the task attributed to
     * appended entries.
     */
    commitWith<T>(change: (tx: Transaction) => T | Promise<T>, context: Context, scope?: TransactionScope): Promise<T>;
    /** Internal: run a read-only job on the mutation line so multi-read derivations observe one committed state. */
    readOnLine<T>(job: () => Promise<T>): Promise<T>;
    /**
     * Internal: a conversation document's current incarnation and value, for a job already running on the line (see
     * `readOnLine()`). Absent documents are `undefined`.
     */
    conversationDocumentOnLine(token: ConversationDocToken<JsonObject>, conversationId: ConversationId, context: Context): Promise<{
        readonly record: DocumentRecord;
        readonly version: number;
        readonly value: JsonObject;
    } | undefined>;
    snapshot<T extends JsonObject>(token: SessionDocToken<T>, context: Context): Promise<Readonly<T> | undefined>;
    snapshot<T extends JsonObject>(token: ConversationDocToken<T>, conversationId: ConversationId, context: Context): Promise<Readonly<T> | undefined>;
    snapshot<T extends JsonObject>(token: TaskDocToken<T>, taskId: TaskId, context: Context): Promise<Readonly<T> | undefined>;
    snapshot<T extends JsonObject, I extends JsonValue>(token: SessionDocFamilyToken<T, I>, key: string, context: Context): Promise<Readonly<T> | undefined>;
    snapshot<T extends JsonObject, I extends JsonValue>(token: ConversationDocFamilyToken<T, I>, conversationId: ConversationId, key: string, context: Context): Promise<Readonly<T> | undefined>;
    snapshot<T extends JsonObject, I extends JsonValue>(token: TaskDocFamilyToken<T, I>, taskId: TaskId, key: string, context: Context): Promise<Readonly<T> | undefined>;
    documentState<T extends JsonObject>(token: SessionDocToken<T>, context: Context): Promise<DocumentState<T> | undefined>;
    documentState<T extends JsonObject>(token: ConversationDocToken<T>, conversationId: ConversationId, context: Context): Promise<DocumentState<T> | undefined>;
    documentState<T extends JsonObject>(token: TaskDocToken<T>, taskId: TaskId, context: Context): Promise<DocumentState<T> | undefined>;
    documentState<T extends JsonObject, I extends JsonValue>(token: SessionDocFamilyToken<T, I>, key: string, context: Context): Promise<DocumentState<T> | undefined>;
    documentState<T extends JsonObject, I extends JsonValue>(token: ConversationDocFamilyToken<T, I>, conversationId: ConversationId, key: string, context: Context): Promise<DocumentState<T> | undefined>;
    documentState<T extends JsonObject, I extends JsonValue>(token: TaskDocFamilyToken<T, I>, taskId: TaskId, key: string, context: Context): Promise<DocumentState<T> | undefined>;
    watchDoc<T extends JsonObject>(token: SessionDocToken<T>, context: Context): Promise<DocumentWatch<T> | undefined>;
    watchDoc<T extends JsonObject>(token: ConversationDocToken<T>, conversationId: ConversationId, context: Context): Promise<DocumentWatch<T> | undefined>;
    watchDoc<T extends JsonObject>(token: TaskDocToken<T>, taskId: TaskId, context: Context): Promise<DocumentWatch<T> | undefined>;
    watchDoc<T extends JsonObject, I extends JsonValue>(token: SessionDocFamilyToken<T, I>, key: string, context: Context): Promise<DocumentWatch<T> | undefined>;
    watchDoc<T extends JsonObject, I extends JsonValue>(token: ConversationDocFamilyToken<T, I>, conversationId: ConversationId, key: string, context: Context): Promise<DocumentWatch<T> | undefined>;
    watchDoc<T extends JsonObject, I extends JsonValue>(token: TaskDocFamilyToken<T, I>, taskId: TaskId, key: string, context: Context): Promise<DocumentWatch<T> | undefined>;
    snapshotAsOf<T extends JsonObject>(token: RewindableConversationDocToken<T>, conversationId: ConversationId, at: EntryId, context: Context): Promise<Readonly<T> | undefined>;
    snapshotAsOf<T extends JsonObject, I extends JsonValue>(token: RewindableConversationDocFamilyToken<T, I>, conversationId: ConversationId, key: string, at: EntryId, context: Context): Promise<Readonly<T> | undefined>;
    close(context: Context): Promise<void>;
    /**
     * Internal: the Session's failure, and errors of listeners, which never fail what ran them; `info` defaults to a
     * listener. A plain Session drops them.
     */
    report(_error: unknown, _info?: ReportInfo, _context?: Context): void;
    /**
     * Runs inside every transaction that creates or forks a conversation, after the conversation record is staged. A
     * plain Session stages nothing; a Harness stages its built-in documents.
     */
    protected conversationCreated(_tx: Transaction, _record: ConversationRecord): Promise<void>;
    /**
     * Internal, for `beforeClose()`: on the line, after every commit admitted before the seal has settled, write what
     * `writes()` returns then straight to Storage. Nothing is published, since the Session is closing; a failed Session
     * writes nothing.
     */
    protected writeAtClose(writes: () => readonly StorageWrite[]): Promise<void>;
    /** Runs after close seals admission and before the line closes Storage; must not reject. */
    protected beforeClose(): Promise<void>;
    /** Register a synchronous post-adoption listener. It must not block or call Session operations; a throw is reported. */
    subscribeCommits(listener: (publication: CommitPublication, context: Context) => void): () => void;
    /**
     * Internal: `subscribeCommits()` for the Session's own components, whose state follows each commit. A throw leaves
     * that state behind storage, so it fails the Session instead of being reported. They run before host listeners.
     */
    observeCommits(listener: (publication: CommitPublication, context: Context) => void): () => void;
    /**
     * Register a listener called synchronously when close begins, also when a failure closes the Session (`failure` is
     * then set). It must not block or call Session operations; a throw is reported.
     */
    subscribeClose(listener: () => void): () => void;
    /** Drop every loaded tracker on the mutation line; later access cold-loads from Storage. */
    unloadDocuments(): Promise<void>;
    /**
     * Internal, for tests: how many documents the cache holds, how many are idle, how many incarnations are pinned, and how
     * many sweep jobs were queued on the line so far.
     */
    get documentCacheSizes(): {
        readonly cached: number;
        readonly idle: number;
        readonly attached: number;
        readonly sweeps: number;
    };
    /** Internal: throw `SessionFailed` when failed, else an error when closing. */
    assertUsable(): void;
}
/**
 * Run a host callback that must not fail its caller: a throw, or a promise it returns that rejects, goes to `onError`,
 * which is not awaited.
 */
export declare function contained(callback: () => unknown, onError: (error: unknown) => void): void;
