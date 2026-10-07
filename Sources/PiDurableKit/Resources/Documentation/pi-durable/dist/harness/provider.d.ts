import type { Context } from "@earendil-works/chord";
import type { TaskRuntime } from "../types.ts";
/** Stable provider-facing identity of one conversation. */
export type ProviderState = {
    sessionId: string;
};
/** Built-in provider state; every fork starts with a fresh identity instead of copying its parent. */
export declare const ProviderDoc: import("../types.ts").ConversationDocToken<ProviderState>;
/**
 * Return the persisted identity without writing in the normal path. A legacy conversation without `pi.provider` gets
 * one migration commit whose `tx.doc()` runs `initial()` before the provider request starts.
 */
export declare function ensureProviderSessionId<I, S, R, H extends object>(runtime: TaskRuntime<I, S, R, H>, context: Context): Promise<string>;
