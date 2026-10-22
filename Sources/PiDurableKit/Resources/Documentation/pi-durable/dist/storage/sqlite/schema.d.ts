export { validateSqliteSchemaPrefix } from "@earendil-works/chord/sqlite";
/**
 * Immutable identifier history for migrations and runtime queries. Never change or remove an existing value; a
 * rename adds a new entry so historical migrations keep rendering their original object names.
 */
declare const TABLE_NAMES: {
    readonly durableSchema: "durable_schema";
    readonly durableMetadata: "durable_metadata";
    readonly recordIds: "record_ids";
    readonly conversations: "conversations";
    readonly entries: "entries";
    readonly tasks: "tasks";
    readonly submissions: "submissions";
    readonly documents: "documents";
    readonly documentRevisions: "document_revisions";
};
declare const INDEX_NAMES: {
    readonly conversationsByOwnerConversation: "conversations_by_owner_conversation";
    readonly conversationsByOwnerTask: "conversations_by_owner_task";
    readonly entriesByConversation: "entries_by_conversation";
    readonly entryHeadsByConversation: "entry_heads_by_conversation";
    readonly tasksByStatus: "tasks_by_status";
    readonly tasksByConversation: "tasks_by_conversation";
    readonly tasksByKind: "tasks_by_kind";
    readonly tasksByAbortRequested: "tasks_by_abort_requested";
    readonly tasksByBackground: "tasks_by_background";
    readonly submissionsByRequest: "submissions_by_request";
    readonly submissionsByConversation: "submissions_by_conversation";
    readonly submissionsByStatus: "submissions_by_status";
    readonly documentsByAddress: "documents_by_address";
    readonly documentsByScope: "documents_by_scope";
    readonly documentsByScopeKind: "documents_by_scope_kind";
    readonly documentRevisionsByKind: "document_revisions_by_kind";
};
type SqliteIdentifiers<T extends Record<string, string>> = {
    readonly [K in keyof T]: string;
};
export type SqliteSchema = {
    readonly tables: SqliteIdentifiers<typeof TABLE_NAMES>;
    readonly indexes: SqliteIdentifiers<typeof INDEX_NAMES>;
};
/** Build the identifiers used by every migration and storage query. */
export declare function createSqliteSchema(prefix?: string): SqliteSchema;
export declare const DEFAULT_SQLITE_SCHEMA: SqliteSchema;
