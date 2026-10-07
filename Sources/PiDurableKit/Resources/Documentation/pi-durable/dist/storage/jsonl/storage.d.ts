import type { Context, JsonValue } from "@earendil-works/chord";
import type { FileSystem } from "../../env/index.ts";
import type { ConversationId, ConversationQuery, Cursor, DocumentAddress, DocumentId, DocumentPoint, DocumentQuery, EntryId, EntryQuery, Id, Seq, Storage, StorageWrite, SubmissionId, SubmissionQuery, TaskId, TaskQuery } from "../../types.ts";
export type JsonlStorageOptions = {
    /** Flush every affected sidecar before appending the main marker. Defaults to false. */
    readonly fsync?: boolean;
};
export declare class JsonlCorruptionError extends Error {
    constructor(message: string, cause?: Error);
}
export declare class JsonlStoragePoisonedError extends Error {
    constructor(cause: Error);
}
/** Portable JSONL implementation of the storage contract. */
export declare class JsonlStorage implements Storage {
    private readonly fs;
    private readonly directory;
    private readonly mainPath;
    private readonly fsync;
    private readonly memory;
    private readonly currentOnlyDocuments;
    private readonly liveTaskSidecars;
    private closed;
    private poisonError;
    private constructor();
    /** Open or create a JSONL storage directory using the supplied filesystem. */
    static open(directory: string, fs: FileSystem, context: Context, options?: JsonlStorageOptions): Promise<JsonlStorage>;
    commit(writes: readonly StorageWrite[], context: Context): Promise<Seq>;
    mintId<I extends Id<string>>(): Promise<I>;
    conversation(id: ConversationId, context: Context): Promise<import("../../types.ts").ConversationRecord | undefined>;
    scanConversations(query: ConversationQuery, limit: number, cursor: Cursor | undefined, context: Context): Promise<import("../../types.ts").Page<import("../../types.ts").ConversationRecord, Readonly<Record<string, JsonValue>>>>;
    entry(id: EntryId, context: Context): ReturnType<Storage["entry"]>;
    entry(conversationId: ConversationId, id: EntryId, context: Context): ReturnType<Storage["entry"]>;
    findLatestHeadMarker(conversationId: ConversationId, atOrBeforeEntryId: EntryId | undefined, context: Context): Promise<(import("../../types.ts").EntryRecord & {
        readonly head: EntryId;
    }) | undefined>;
    scanEntries(query: EntryQuery, limit: number, cursor: Cursor | undefined, context: Context): Promise<import("../../types.ts").Page<import("../../types.ts").EntryRecord, Readonly<Record<string, JsonValue>>>>;
    task(id: TaskId, context: Context): Promise<({
        readonly id: TaskId<JsonValue>;
        readonly conversationId: ConversationId;
        readonly kind: string;
        readonly version: number;
        readonly input: JsonValue;
        readonly owner?: TaskId;
        readonly background: boolean;
        readonly abortRequested: boolean;
        readonly startedAt?: number;
        readonly endedAt?: number;
    } & ({
        readonly state: {
            readonly status: "pending";
            readonly checkpoint: JsonValue;
            readonly outcome?: never;
        } | {
            readonly status: "running";
            readonly checkpoint: JsonValue;
            readonly outcome?: never;
        } | {
            readonly status: "waiting";
            readonly checkpoint: JsonValue;
            readonly on: readonly TaskId[];
            readonly policy: import("../../types.ts").JoinPolicy;
            readonly outcome?: never;
        };
        readonly memos?: Readonly<Record<string, JsonValue>>;
    } | {
        readonly state: {
            readonly status: "completing";
            readonly checkpoint?: never;
            readonly outcome: import("../../types.ts").TaskOutcome<JsonValue>;
        } | {
            readonly status: "terminal";
            readonly checkpoint?: never;
            readonly outcome: import("../../types.ts").TaskOutcome<JsonValue>;
        };
        readonly memos?: never;
    })) | undefined>;
    scanTasks(query: TaskQuery, limit: number, cursor: Cursor | undefined, context: Context): Promise<import("../../types.ts").Page<{
        readonly id: TaskId<JsonValue>;
        readonly conversationId: ConversationId;
        readonly kind: string;
        readonly version: number;
        readonly input: JsonValue;
        readonly owner?: TaskId;
        readonly background: boolean;
        readonly abortRequested: boolean;
        readonly startedAt?: number;
        readonly endedAt?: number;
    } & ({
        readonly state: {
            readonly status: "pending";
            readonly checkpoint: JsonValue;
            readonly outcome?: never;
        } | {
            readonly status: "running";
            readonly checkpoint: JsonValue;
            readonly outcome?: never;
        } | {
            readonly status: "waiting";
            readonly checkpoint: JsonValue;
            readonly on: readonly TaskId[];
            readonly policy: import("../../types.ts").JoinPolicy;
            readonly outcome?: never;
        };
        readonly memos?: Readonly<Record<string, JsonValue>>;
    } | {
        readonly state: {
            readonly status: "completing";
            readonly checkpoint?: never;
            readonly outcome: import("../../types.ts").TaskOutcome<JsonValue>;
        } | {
            readonly status: "terminal";
            readonly checkpoint?: never;
            readonly outcome: import("../../types.ts").TaskOutcome<JsonValue>;
        };
        readonly memos?: never;
    }), Readonly<Record<string, JsonValue>>>>;
    submission(id: SubmissionId, context: Context): Promise<import("../../types.ts").SubmissionRecord | undefined>;
    scanSubmissions(query: SubmissionQuery, limit: number, cursor: Cursor | undefined, context: Context): Promise<import("../../types.ts").Page<import("../../types.ts").SubmissionRecord, Readonly<Record<string, JsonValue>>>>;
    submissionByRequest(conversationId: ConversationId, requestId: string, context: Context): Promise<import("../../types.ts").SubmissionRecord | undefined>;
    findDocument(address: DocumentAddress, at: DocumentPoint, context: Context): Promise<import("../../types.ts").DocumentRecord | undefined>;
    document(id: DocumentId, at: DocumentPoint, context: Context): Promise<import("../../types.ts").StoredDocument | undefined>;
    scanDocuments(query: DocumentQuery, limit: number, cursor: Cursor | undefined, context: Context): Promise<import("../../types.ts").Page<import("../../types.ts").DocumentRecord, Readonly<Record<string, JsonValue>>>>;
    close(context: Context): Promise<void>;
    private encodeCommit;
    private planReclamations;
    private adoptSidecarState;
    /** The marker already published this state, so reclamation is retryable best-effort maintenance. */
    private reclaimSidecars;
    private replaceSidecar;
    private recover;
    private static confirmRecord;
    private static readLines;
    private resolveFile;
    private get store();
    private poison;
    private assertUsable;
}
