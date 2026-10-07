import { type Draft, type JsonRepresentation } from "@earendil-works/chord";
import type { Usage } from "@earendil-works/pi-ai";
import type { ConversationId, Tx } from "../types.ts";
/** Ledger of one conversation's own spend: its entries, and compaction summarization attempts, which have none. */
export type UsageState = {
    /** Assistant entries and summarization attempts, keyed `provider/modelId`. */
    models: Record<string, JsonRepresentation<Usage>>;
    /** Tool results, keyed by tool name; their usage has no model identity. */
    tools: Record<string, JsonRepresentation<Usage>>;
};
export declare const UsageDoc: import("../types.ts").ConversationDocToken<UsageState>;
/** Add `usage` to one bucket of the conversation's `pi.usage`, in the commit that records the response. */
export declare function recordUsage(tx: Tx, conversationId: ConversationId, bucket: keyof UsageState, key: string, usage: Usage): Promise<void>;
/** Add every counter of `usage` to `total`; optional counters are added once either side reports them. */
export declare function addUsage(total: Draft<Usage> | Usage, usage: Usage): void;
/** Add every bucket of `state` into `sum`. */
export declare function addUsageState(sum: UsageState, state: Readonly<UsageState>): void;
