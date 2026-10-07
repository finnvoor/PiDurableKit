import { type Context, type JsonValue } from "@earendil-works/chord";
import type { CommitPublication, ConversationDocFamilyToken, ConversationDocToken, ConversationId, ConversationRecord, DocumentRecord, DocumentState, DocumentWatch, EntryId, JsonObject, RewindableConversationDocFamilyToken, RewindableConversationDocToken, Session, SessionDocFamilyToken, SessionDocToken, Storage, TaskDocFamilyToken, TaskDocToken, TaskId, Tx } from "../types.ts";
import { Transaction, type TransactionScope } from "./transaction.ts";
/** Open a Session kernel over one storage backend. `now` is the wall clock for task times; default `Date.now`. */
export declare function createSession(storage: Storage, options?: {
    readonly now?: () => number;
}): Session;
/**
 * Session kernel: one mutation line, the loaded document tracker cache, and committed publication.
 *
 * Only committed state is observable. Every commit callback, preparation, Storage settlement, adoption, and
 * publication enqueue runs while the line is held; listeners run later.
 */
export declare class SessionImpl implements Session {
    #private;
    constructor(storage: Storage, now?: () => number);
    commit<T>(change: (tx: Tx) => T | Promise<T>, context: Context): Promise<T>;
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
     * Runs inside every transaction that creates or forks a conversation, after the conversation record is staged. A
     * plain Session stages nothing; a Harness stages its built-in documents.
     */
    protected conversationCreated(_tx: Transaction, _record: ConversationRecord): Promise<void>;
    /** Runs after close seals admission and before the line closes Storage; must not reject. */
    protected beforeClose(): Promise<void>;
    /** Register a synchronous post-adoption listener. It must not throw, block, or call Session operations. */
    subscribeCommits(listener: (publication: CommitPublication, context: Context) => void): () => void;
    /** Register a listener called synchronously when close begins. It must not throw, block, or call Session operations. */
    subscribeClose(listener: () => void): () => void;
    /** Drop every loaded tracker on the mutation line; later access cold-loads from Storage. */
    unloadDocuments(): Promise<void>;
}
