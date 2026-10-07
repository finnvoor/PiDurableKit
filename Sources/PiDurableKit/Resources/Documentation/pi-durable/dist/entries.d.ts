import type { JsonValue } from "@earendil-works/chord";
import type { CompactionReason, ToolDiagnostic } from "./harness/types.ts";
import type { Entry } from "./types.ts";
/** Define a typed entry kind whose `is()` guard narrows by `EntryRecord.kind`. */
export declare function defineEntry<D extends JsonValue = never>(kind: string): Entry<D>;
/** User input: `model` is `[UserMessage]`. Written by submissions. */
export declare const UserEntry: Entry<never>;
/** Provider result with any stop reason: `model` is `[AssistantMessage]`. Written by generation. */
export declare const AssistantEntry: Entry<never>;
/** Positional prompt and tool change: `model` is `[SystemMessage]` with empty `content`. */
export declare const SystemEntry: Entry<never>;
/**
 * Tool result: `model` is `[ToolResultMessage]`, whose content ends with the rendered diagnostics block; `data` holds
 * the structured diagnostics, possibly none. Written by tool tasks, and by generation for calls it did not offer.
 */
export declare const ToolResultEntry: Entry<{
    diagnostics: ToolDiagnostic[];
}>;
/**
 * Start of a new context: always `head: "self"`, with `model` absent for a plain reset or `[UserMessage]` carrying the
 * handoff text. Written by `Conversation.reset()` and the `handoff` tool control.
 */
export declare const ResetEntry: Entry<never>;
/**
 * Compaction summary: `model` is `[UserMessage]` with the wrapped summary, `head` the first kept entry. Written by
 * compaction tasks, directly or through a write submission.
 */
export declare const CompactionEntry: Entry<{
    reason: CompactionReason;
}>;
