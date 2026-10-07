import type { ConversationId } from "./types.ts";
/** A transaction read a table after its first table write. Read every required row before writing. */
export declare class ReadAfterWrite extends Error {
    constructor(method: string);
}
/** Storage rejected a batch before any durable effect; the owning Session may continue safely. */
export declare class StorageRejected extends Error {
    constructor(message: string, options?: ErrorOptions);
}
/** A submission reached a busy conversation and was not admitted. */
export declare class ConversationBusy extends Error {
    readonly conversationId: ConversationId;
    constructor(conversationId: ConversationId);
}
