import type { ToolCall } from "@earendil-works/pi-ai";
import type { ConversationId, EntryId, JsonObject, Task, Tx, TypedEntry } from "../types.ts";
import type { ToolControl, ToolDiagnostic, ToolExecutionResult, ToolHooks } from "./types.ts";
export type ToolTaskInput = {
    assistant: EntryId;
    callId: string;
};
export type ToolTaskCheckpoint = {
    phase: "call";
}
/** Durable intent: the final arguments and the replay policy recorded before execution. */
 | {
    phase: "execute";
    arguments: JsonObject;
    replay: "safe" | "unsafe";
};
export type ToolTaskResult = {
    entryId: EntryId;
    control?: ToolControl;
};
/**
 * Built-in tool task: resolves the called tool among its phase agent's tools, validates, runs `beforeTool`, records intent,
 * executes, runs `afterTool`, and appends the result, all in one `call` handler so nothing separates resolution from
 * settlement. `execute` is reached only by recovery and applies the replay rule.
 */
export declare const ToolTask: Task<ToolTaskInput, ToolTaskCheckpoint, ToolTaskResult, ToolHooks>;
/** An error result the Harness writes itself: no content and one `error` diagnostic with `code`. */
export declare function harnessError(code: string, message: string): ToolExecutionResult;
/**
 * Append a `pi.tool-result` entry. The content ends with the rendered diagnostics, so the stored message is exactly
 * what the model sees; `data` keeps the structured list. A result's usage is added to `pi.usage` in the same commit.
 */
export declare function appendToolResult(tx: Tx, conversationId: ConversationId, call: ToolCall, result: ToolExecutionResult, timestamp: number, durationMs?: number): Promise<TypedEntry<{
    diagnostics: ToolDiagnostic[];
}>>;
