import type { Message, ModelThinkingLevel } from "@earendil-works/pi-ai";
import type { ConversationId, EntryId, TaskId, Tx } from "../types.ts";
import type { CompactionHooks, CompactionReason, CompactionResult, ContextView, ConversationStreamOptions, ModelRef } from "./types.ts";
export type CompactionInput = {
    reason: CompactionReason;
    instructions?: string;
};
/** The pinned summarization request. */
export type SummaryRequest = {
    attempt: number;
    model: ModelRef;
    thinkingLevel: ModelThinkingLevel;
    streamOptions: ConversationStreamOptions;
    maxTokens: number;
    /** Newest entry of the context the range was selected from. */
    tail: EntryId;
    /** First entry kept verbatim; the summary's `head`. */
    firstKept: EntryId;
};
export type CompactionCheckpoint = {
    phase: "select";
} | ({
    phase: "summarize";
} & SummaryRequest) | ({
    phase: "retry";
    until: number;
} & SummaryRequest);
/**
 * Built-in compaction task (spec §8.7): select an old prefix of the model context, summarize it, and place a summary
 * entry whose `head` is the first kept entry. A compaction the generation owns blocks it and appends directly; a
 * conversation-owned one places its summary through a write submission.
 */
export declare const CompactionTask: import("../types.ts").Task<CompactionInput, CompactionCheckpoint, CompactionResult, CompactionHooks>;
/**
 * Create a compaction task with its status in this commit. `owner` is the generation that waits for it (a blocking
 * compaction); without one it is conversation-owned, and `background` unless it is manual.
 */
export declare function createCompaction(tx: Tx, conversationId: ConversationId, input: CompactionInput, owner?: TaskId): Promise<TaskId<CompactionResult>>;
/**
 * Index in `view.entries` of the first entry a summary keeps, or `undefined` when there is nothing to compact
 * (spec §8.7). Walks back from the tail until `keepRecentTokens` are kept, then cuts at the first candidate at or after
 * that entry: an entry whose contribution starts with a user or assistant message, never a tool result, and never a
 * user entry that a result of the preceding assistant's calls still follows.
 */
export declare function selectCut(view: ContextView, keepRecentTokens: number): number | undefined;
/** Model messages of the entries before `cut`: the head marker first, ordered like model context (spec §2.1). */
export declare function summarizedMessages(view: ContextView, cut: number): Message[];
/**
 * Size of a request over `view` followed by `extra` (spec §8.3): the usage of the newest assistant appended after the
 * head marker, whose request included the marker, plus estimates of the messages after it; without one, estimates of
 * every message.
 */
export declare function estimateContext(view: ContextView, extra: readonly Message[]): number;
/** Messages as plain text, so the summarizer reads a transcript instead of continuing it. System messages are omitted. */
export declare function serializeConversation(messages: readonly Message[]): string;
