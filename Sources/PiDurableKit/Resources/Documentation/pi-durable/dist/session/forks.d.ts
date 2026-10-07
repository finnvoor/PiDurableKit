import type { Context } from "@earendil-works/chord";
import type { ConversationId, DocumentCopySource, DocumentCreate, EntryId, Storage } from "../types.ts";
/** One definition-free document copy to create with a forked conversation. */
export type ForkDocumentCopy = {
    readonly record: DocumentCreate;
    readonly source: DocumentCopySource;
};
/** Select every persisted conversation document copied by one fork. */
export declare function prepareForkDocumentCopies(storage: Storage, parentConversationId: ConversationId, at: EntryId, childConversationId: ConversationId, context: Context): Promise<readonly ForkDocumentCopy[]>;
