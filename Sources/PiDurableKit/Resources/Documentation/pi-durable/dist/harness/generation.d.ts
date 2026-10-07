import { type Draft } from "@earendil-works/chord";
import type { DeferredHandle, ModelThinkingLevel } from "@earendil-works/pi-ai";
import type { ConversationId, EntryId, SubmissionId, TaskId, Tx } from "../types.ts";
import { type LiveState } from "./live.ts";
import { type ToolTaskResult } from "./tool.ts";
import type { CompactionResult, ConversationStreamOptions, GenerationHooks, ModelRef } from "./types.ts";
export type GenerationInput = Record<string, never>;
export type GenerationCheckpoint = {
    phase: "prepare";
    attempt: number;
    /** The blocking compaction this generation waited for; it starts no other compaction (spec §8.3). */
    compacted?: TaskId<CompactionResult>;
    /** Error text of the overflow that started `compacted`; checked once when `prepare` resumes. */
    overflow?: string;
} | {
    phase: "request";
    attempt: number;
    compacted?: TaskId<CompactionResult>;
    model: ModelRef;
    thinkingLevel: ModelThinkingLevel;
    /** The settings' request options when preparation committed; a resend after recovery uses them unchanged. */
    streamOptions: ConversationStreamOptions;
    /** Newest entry included in the request. */
    cutoff: EntryId;
} | {
    phase: "retry";
    attempt: number;
    compacted?: TaskId<CompactionResult>;
    until: number;
} | {
    phase: "poll";
    attempt: number;
    compacted?: TaskId<CompactionResult>;
    model: ModelRef;
    cutoff: EntryId;
    handle: DeferredHandle;
    pollAt: number;
} | {
    /** Waiting on the round's tool tasks, which the generation owns (spec §8.5). */
    phase: "tools";
    /** The tool-calling answer. */
    assistant: EntryId;
    /** Tool tasks created so far, in call order; grows by one per started call of a sequential round. */
    tools: TaskId<ToolTaskResult>[];
    /** Calls of a sequential round not started yet, in call order. */
    pending: string[];
};
export type GenerationResult = {
    entryId: EntryId;
};
/**
 * Built-in generation task: prepares the positional system prompt and tool loadout, requests or polls the model,
 * retries, and classifies the response. The run's inputs live in `pi.live.run`.
 */
export declare const GenerationTask: import("../types.ts").Task<GenerationInput, GenerationCheckpoint, GenerationResult, GenerationHooks>;
/**
 * Append a committed partial left by an interrupted, aborted, faulted, or orphaned attempt as an aborted assistant
 * entry; the caller replaces or removes `generation`.
 */
export declare function convertPartial(tx: Tx, live: Draft<LiveState>, conversationId: ConversationId): Promise<void>;
/** Start a run for `inputs`, placed input submissions: a new generation takes `pi.live.run`. */
export declare function startRun(tx: Tx, conversationId: ConversationId, live: Draft<LiveState>, inputs: SubmissionId[]): Promise<void>;
/** Hand run control from `from` to `to`; the run's inputs move with it. */
export declare function handOver(live: Draft<LiveState>, from: TaskId, to: TaskId): void;
