import type { Context, JsonValue } from "@earendil-works/chord";
import type { ConversationId, ConversationQuery, ConversationRecord, Cursor, DocumentAddress, DocumentId, DocumentPoint, DocumentQuery, DocumentRecord, EntryId, EntryQuery, EntryRecord, Id, Page, Seq, Storage, StorageWrite, StoredDocument, SubmissionId, SubmissionQuery, SubmissionRecord, TaskId, TaskQuery, TaskRecord } from "../types.ts";
type StoredTask = TaskRecord<JsonValue, JsonValue, JsonValue>;
/** A fully validated, detached state mutation whose application performs no fallible preparation. */
export interface PreparedMemoryCommit {
    readonly seq: Seq;
    /** Deeply frozen detached writes for persistence. */
    readonly writes: readonly StorageWrite[];
    apply(): Seq;
}
/**
 * Detached in-memory reference implementation of `Storage`.
 *
 * Reads and retained writes are cloned intentionally to match the ownership boundary
 * of serialization-backed stores. This is backend conformance, not validation.
 */
export declare class MemoryStorage implements Storage {
    private readonly state;
    private nextId;
    private nextSeq;
    private closed;
    commit(writes: readonly StorageWrite[], _context: Context): Promise<Seq>;
    /** Validate and detach one commit without changing observable state. */
    prepareCommit(writes: readonly StorageWrite[], seq?: Seq): PreparedMemoryCommit;
    private resolveDocumentCopies;
    private applyPreparedCommit;
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
    private materializeDocument;
    private visibleEntries;
    /** Visible entries oldest first: the fork chain's segments from the root conversation forward. */
    private visibleEntriesAscending;
    private checkGlobalIds;
    private prepareDocumentActions;
    private checkDocumentActions;
    private applyDocumentActions;
    private assertOpen;
}
export {};
