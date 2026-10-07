import type { ConversationId, ConversationRecord, Tx } from "../types.ts";
import type { Agent, AgentChange, AgentState, CompactionPolicy, ConversationRetryPolicy, HarnessSettings, ProgressPolicy, RegistrySnapshot, Settings, ToolRegistration } from "./types.ts";
export declare const DEFAULT_RETRY_POLICY: ConversationRetryPolicy;
export declare const DEFAULT_COMPACTION_POLICY: CompactionPolicy;
export declare const DEFAULT_PROGRESS_POLICY: ProgressPolicy;
/** The reserved section key of the agent's `instructions`. */
export declare const INSTRUCTIONS_KEY = "instructions";
/** Built-in agent document; rewindable so forks start from the agent at their fork entry. */
export declare const AgentDoc: import("../types.ts").RewindableConversationDocToken<AgentState>;
/** Resolve the host settings: every field over its built-in default, object fields merged. */
export declare function resolveSettings(settings: HarnessSettings | undefined): Settings;
/** Apply one change to `pi.agent`: a given field replaces the stored one, `null` clears it, `undefined` changes nothing. */
export declare function configure(tx: Tx, conversationId: ConversationId, change: AgentChange): Promise<void>;
/**
 * `addTools` of a tool round: an array gets each name it lacks appended, `{ remove }` loses the names, and unset tools
 * already offer every tool, so nothing is written.
 */
export declare function addTools(tx: Tx, conversationId: ConversationId, added: readonly string[]): Promise<void>;
/**
 * Built-in part of every Harness commit that creates or forks a conversation, for `pi.agent`: a fork keeps its `asOf`
 * copy; a new task-owned conversation copies the stored agent of its owner task's conversation; a new ownerless one
 * starts empty.
 */
export declare function createAgent(tx: Tx, conversation: ConversationRecord): Promise<void>;
/** Handlers of the selected extensions' hooks for a task name, in extension order. */
export declare function agentHooks(agent: Agent, taskName: string): object[];
/**
 * Resolve an agent from its stored state (absent: every field unset), a registry snapshot, and resolved settings. A
 * wrapper that throws or renames drops its target and is reported; a wrapper without a target does nothing.
 */
export declare function resolveAgent<Tool extends ToolRegistration>(state: Readonly<AgentState> | undefined, snapshot: RegistrySnapshot<Tool>, settings: Settings, report: (error: unknown) => void): Agent<Tool>;
