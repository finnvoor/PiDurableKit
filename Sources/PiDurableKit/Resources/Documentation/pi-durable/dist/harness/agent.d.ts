import type { ConversationId, ConversationRecord, Tx } from "../types.ts";
import type { Agent, AgentChange, AgentState, CompactionPolicy, ConversationRetryPolicy, HarnessSettings, ProgressPolicy, RegistrySnapshot, Settings, ToolRegistration } from "./types.ts";
export declare const DEFAULT_RETRY_POLICY: ConversationRetryPolicy;
export declare const DEFAULT_COMPACTION_POLICY: CompactionPolicy;
export declare const DEFAULT_PROGRESS_POLICY: ProgressPolicy;
/** The reserved section key of the agent's `instructions`. */
export declare const INSTRUCTIONS_KEY = "instructions";
/** Built-in agent document; rewindable so forks start from the agent at their fork entry. */
export declare const AgentDoc: import("../types.ts").RewindableConversationDocToken<AgentState>;
/** Default `settings.restartLimit`. */
export declare const DEFAULT_RESTART_LIMIT = 5;
/** Resolve the host settings: every field over its built-in default, object fields merged. */
export declare function resolveSettings(settings: HarnessSettings | undefined): Settings;
/** Apply one change to `pi.agent`: a given field replaces the stored one, `null` clears it, `undefined` changes nothing. */
export declare function configure(tx: Tx, conversationId: ConversationId, change: AgentChange): Promise<void>;
/**
 * `addTools` of a tool round, applied to `tools` and `modelTools`, so the next request offers the tools: an array gets
 * each name it lacks appended, and `{ remove }` loses the names. An unset `tools` already enables every tool, so nothing
 * is written for it. An unset or object `modelTools` also gets each name appended to its `add`, which loads deferred
 * tools and has no effect for others. By name, without the registry: a tool that is not registered now, such as one of
 * an MCP server that is reconnecting, is offered once it is again.
 */
export declare function addTools(tx: Tx, conversationId: ConversationId, added: readonly string[]): Promise<void>;
/**
 * Built-in part of every Harness commit that creates or forks a conversation, for `pi.agent`: a fork keeps its `asOf`
 * copy; a new task-owned conversation copies the stored agent of its owner task's conversation; a new ownerless one
 * starts empty.
 */
export declare function createAgent(tx: Tx, conversation: ConversationRecord): Promise<void>;
/** Handlers of the selected extensions' hooks for a task name, in extension order. */
export declare function agentHooks(agent: Agent, taskName: string): {
    readonly extension: string;
    readonly handlers: object;
}[];
/** The extension whose code a section of `agent` runs: the last selected one that provides or wraps it. */
export declare function sectionExtension(agent: Agent, key: string): string | undefined;
/** The extension whose code a tool of `agent` runs: the last selected one that provides or wraps it. */
export declare function toolExtension(agent: Agent, name: string): string | undefined;
/**
 * Resolve an agent from its stored state (absent: every field unset), a registry snapshot, and resolved settings. A
 * wrapper that throws or renames drops its target and is reported; a wrapper without a target does nothing.
 */
export declare function resolveAgent<Tool extends ToolRegistration>(state: Readonly<AgentState> | undefined, snapshot: RegistrySnapshot<Tool>, settings: Settings, 
/** Gets a wrapper's failure with the name of the wrapper's extension. */
report: (error: unknown, extension: string) => void): Agent<Tool>;
