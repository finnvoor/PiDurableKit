import type { Context, JsonValue } from "@earendil-works/chord";
import type { ConversationId, ConversationQuery, ConversationRecord, Cursor, DocumentAddress, DocumentId, DocumentPoint, DocumentQuery, DocumentRecord, EntryId, EntryQuery, EntryRecord, Id, Page, Seq, Storage, StorageWrite, StoredDocument, SubmissionId, SubmissionQuery, SubmissionRecord, TaskId, TaskQuery, TaskRecord } from "../types.ts";
type StoredTask = TaskRecord<JsonValue, JsonValue, JsonValue>;
type IndexedDbStorageOptions = {
    readonly indexedDB?: IDBFactory;
};
/** Browser IndexedDB implementation of the durable storage contract. One owner must serialize access to each database. */
export declare class IndexedDbStorage implements Storage {
    private readonly database;
    private closed;
    private closing;
    private activeOperations;
    private operationsDrained;
    private constructor();
    /** Open or create a browser-only IndexedDB database. */
    static open(name: string, options?: IndexedDbStorageOptions): Promise<IndexedDbStorage>;
    /** Delete a closed database. Open connections in this or another owner can block deletion. */
    static delete(name: string, options?: IndexedDbStorageOptions): Promise<void>;
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
    private transaction;
    private readConversation;
    private readEntriesDescending;
    private readEntriesAscending;
    private materializeDocument;
    private checkGlobalIds;
    private prepareDocumentActions;
    private checkDocumentActions;
    private currentDocumentId;
    private claimId;
    private applyTableWrite;
    private applyDocumentActions;
    private assertOpen;
}
export type { IndexedDbStorageOptions };
