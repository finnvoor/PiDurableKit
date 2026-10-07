import type { Context } from "@earendil-works/chord";
import type { Message, Tool } from "@earendil-works/pi-ai";
import type { TypedEntryDraft } from "../types.ts";
import type { ContextView, PromptInput, PromptSection, ToolRegistration } from "./types.ts";
/** Sections in effect after replaying system messages in order: set in place, `null` deletes, re-adding appends. */
export declare function replaySections(messages: readonly Message[]): Map<string, string>;
/**
 * Render the agent's sections in order. `undefined` omits a section; tagged text is wrapped as `<key>\n...\n</key>`. A
 * section that throws keeps its shown text, if any, and is reported; errors after `context` is aborted propagate.
 */
export declare function renderSections<Tool extends ToolRegistration>(sections: readonly PromptSection<Tool>[], input: PromptInput<Tool>, shown: ReadonlyMap<string, string>, report: (error: unknown) => void, context: Context): Promise<Map<string, string>>;
type SystemDraft = TypedEntryDraft<never>;
/**
 * Plan the `pi.system` entries that make the replayed sections and tools of `view` equal `desired` and `tools` in values
 * and order.
 *
 * - A head marker with no later `pi.system` entry in context: one complete baseline that omits every retained earlier
 *   `pi.system` entry, written even when it restates the replayed values.
 * - Otherwise, when a minimal section patch would leave a different order: remove every shown section, then re-add
 *   every desired section in order.
 * - Otherwise the minimal patch of changed values and `null` removals, or nothing.
 *
 * Tool changes ride on the last planned entry, or on one entry of their own.
 */
export declare function planSystemEntries(view: ContextView, desired: ReadonlyMap<string, string>, tools: readonly Tool[], timestamp: number): SystemDraft[];
export {};
