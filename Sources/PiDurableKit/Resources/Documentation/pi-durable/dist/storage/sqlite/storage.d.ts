import type { Context, JsonValue } from "@earendil-works/chord";
import type { ConversationId, ConversationQuery, ConversationRecord, Cursor, DocumentAddress, DocumentId, DocumentPoint, DocumentQuery, DocumentRecord, EntryId, EntryQuery, EntryRecord, Id, Page, Seq, Storage, StorageWrite, StoredDocument, SubmissionId, SubmissionQuery, SubmissionRecord, TaskId, TaskQuery, TaskRecord } from "../../types.ts";
import type { SqliteDatabase } from "./database.ts";
type StoredTask = TaskRecord<JsonValue, JsonValue, JsonValue>;
/** Portable SQLite implementation of the Pico storage contract. */
export declare class SqliteStorage implements Storage {
    private readonly db;
    private nextId;
    private closed;
    private closing;
    private admittedReads;
    private readsDrained;
    private constructor();
    /** Initialize storage over an owned SQLite database facade. */
    static open(db: SqliteDatabase): Promise<SqliteStorage>;
    commit(writes: readonly StorageWrite[], _context: Context): Promise<Seq>;
    mintId<I extends Id<string>>(): Promise<I>;
    conversation(id: ConversationId, _context: Context): Promise<ConversationRecord | undefined>;
    scanConversations(query: ConversationQuery, limit: number, cursor: Cursor | undefined, _context: Context): Promise<Page<ConversationRecord, Cursor>>;
    entry(id: EntryId, context: Context): Promise<{
        readonly entry: EntryRecord;
        readonly commitSeq: Seq;
    } | undefined>;
    entry(conversationId: ConversationId, id: EntryId, context: Context): Promise<{
        readonly entry: EntryRecord;
        readonly commitSeq: Seq;
    } | undefined>;
    findLatestHeadMarker(conversationId: ConversationId, atOrBeforeEntryId: EntryId | undefined, _context: Context): Promise<(EntryRecord & {
        readonly head: EntryId;
    }) | undefined>;
    scanEntries(query: EntryQuery, limit: number, cursor: Cursor | undefined, _context: Context): Promise<Page<EntryRecord, Cursor>>;
    private readEntry;
    private readLatestHeadMarker;
    private readEntries;
    /** Oldest first: the fork chain's segments from the root conversation forward, each up to its fork point. */
    private readEntriesAscending;
    task(id: TaskId, _context: Context): Promise<StoredTask | undefined>;
    scanTasks(query: TaskQuery, limit: number, cursor: Cursor | undefined, _context: Context): Promise<Page<StoredTask, Cursor>>;
    submission(id: SubmissionId, _context: Context): Promise<SubmissionRecord | undefined>;
    scanSubmissions(query: SubmissionQuery, limit: number, cursor: Cursor | undefined, _context: Context): Promise<Page<SubmissionRecord, Cursor>>;
    submissionByRequest(conversationId: ConversationId, requestId: string, _context: Context): Promise<SubmissionRecord | undefined>;
    findDocument(address: DocumentAddress, at: DocumentPoint, _context: Context): Promise<DocumentRecord | undefined>;
    document(id: DocumentId, at: DocumentPoint, _context: Context): Promise<StoredDocument | undefined>;
    scanDocuments(query: DocumentQuery, limit: number, cursor: Cursor | undefined, _context: Context): Promise<Page<DocumentRecord, Cursor>>;
    close(_context: Context): Promise<void>;
    private closeDatabase;
    /**
     * Run a read that issues several queries. Close waits for admitted reads, so their later queries never reach a
     * closed database. Single-query reads and transactions are already ordered before close by the database.
     */
    private admitRead;
    private readConversation;
    private materializeDocument;
    private candidateNextId;
    private checkGlobalIds;
    private prepareDocumentActions;
    private checkDocumentActions;
    private currentDocumentId;
    private applyTableWrite;
    private claimId;
    private applyDocumentActions;
    private assertOpen;
}
export {};
