// Open harnesses and the conversions every module shares.
import type { Context } from "@earendil-works/chord";
import type {
	Agent,
	AgentChange,
	AnyTask,
	Conversation,
	ConversationId,
	Extension,
	Harness,
	Registry,
	TaskOutcome,
	TaskRecord,
	ToolRegistration,
} from "@earendil-works/pi-durable";
import type { Args } from "./core.ts";

export type HarnessState = {
	readonly id: number;
	harness: Harness;
	readonly registry: Registry;
	readonly settings: { value: Args };
};

export const harnesses = new Map<number, HarnessState>();

export function harnessState(id: number): HarnessState {
	const state = harnesses.get(id);
	if (state === undefined) throw new Error("The harness is closed");
	return state;
}

export async function conversation(args: Args, context: Context): Promise<Conversation> {
	const found = await harnessState(args.harness).harness.conversation(args.conversation as ConversationId, context);
	if (found === undefined) throw Object.assign(new Error(`Conversation ${args.conversation} does not exist`), { name: "NotFound" });
	return found;
}

/** An installed task definition by name, including the built-in ones. */
export function taskDefinition(state: HarnessState, name: string): AnyTask {
	const task = state.registry.snapshot().task(name);
	if (task === undefined) throw Object.assign(new Error(`Task ${name} is not installed`), { name: "NotFound" });
	return task;
}

/** Converts a Swift `AgentChange` (names) into a pi-durable `AgentChange` (objects). */
export function agentChange(state: HarnessState, change: Args | undefined | null): AgentChange | undefined {
	if (change === undefined || change === null) return undefined;
	const snapshot = state.registry.snapshot();
	const extension = (name: string) => snapshot.extension(name) ?? ({ name } as Extension);
	const tool = (name: string) => snapshot.tools().find((entry) => entry.tool.name === name)?.tool ?? ({ name } as ToolRegistration);
	const result: Record<string, unknown> = {};
	for (const key of ["model", "thinkingLevel", "instructions", "cwd"]) {
		if (key in change) result[key] = change[key];
	}
	if ("extensions" in change) {
		const value = change.extensions;
		result.extensions =
			value === null
				? null
				: Array.isArray(value)
					? value.map(extension)
					: { add: value.add?.map(extension), remove: value.remove?.map(extension) };
	}
	if ("tools" in change) {
		const value = change.tools;
		result.tools = value === null ? null : Array.isArray(value) ? value.map(tool) : { remove: value.remove.map(tool) };
	}
	return result as AgentChange;
}

export function describeAgent(agent: Agent) {
	return {
		model: agent.model ?? null,
		thinkingLevel: agent.thinkingLevel,
		extensions: agent.extensions.map((extension) => extension.name),
		tools: agent.tools.map((tool) => tool.name),
		instructions: agent.instructions ?? null,
		cwd: agent.cwd ?? null,
	};
}

/** Task records without their (internal, possibly large) memos. */
export function describeTask(record: TaskRecord<unknown, unknown, unknown> | undefined) {
	if (record === undefined) return null;
	const { memos: _memos, ...rest } = record as TaskRecord<unknown, unknown, unknown> & { memos?: unknown };
	return rest;
}

export function describeOutcomes(outcomes: readonly TaskOutcome<unknown>[]) {
	return outcomes;
}
