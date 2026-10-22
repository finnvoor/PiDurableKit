// Open harnesses and the conversions every module shares.
import type { Context } from "@earendil-works/chord";
import {
	DEFAULT_COMPACTION_POLICY,
	DEFAULT_PROGRESS_POLICY,
	DEFAULT_RESTART_LIMIT,
	DEFAULT_RETRY_POLICY,
	type HarnessSettings,
	type RegistrySnapshot,
	type Settings,
} from "@earendil-works/pi-durable";
import type {
	Agent,
	AgentChange,
	AnyTask,
	Conversation,
	ConversationId,
	Extension,
	Harness,
	HarnessOptions,
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
	/** `HarnessOptions.settings`: live getters over the newest settings Swift sent. */
	harnessSettings?: HarnessSettings;
	/** `HarnessOptions.env`, if the harness has an environment. */
	env?: NonNullable<HarnessOptions["env"]>;
	/** Replaces the models the harness uses, by the Swift `Models` ID. */
	setModels?: (id: number) => void;
};

export const harnesses = new Map<number, HarnessState>();

/** How each opened harness or session ended, kept after it closed so a late caller still learns why. */
export const endings = new Map<number, Promise<{ reason: "closed" } | { reason: "failed"; error: unknown }>>();

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
	if ("modelTools" in change) {
		const value = change.modelTools;
		result.modelTools =
			value === null
				? null
				: Array.isArray(value)
					? value.map(tool)
					: { ...(value.remove ? { remove: value.remove.map(tool) } : {}), ...(value.add ? { add: value.add.map(tool) } : {}) };
	}
	return result as AgentChange;
}

export function describeAgent(agent: Agent) {
	return {
		model: agent.model ?? null,
		thinkingLevel: agent.thinkingLevel,
		extensions: agent.extensions.map((extension) => extension.name),
		tools: agent.tools.map((tool) => tool.name),
		callable: agent.callable.map((tool) => tool.name),
		deferred: agent.deferred.map((tool) => tool.name),
		sections: agent.sections.map((section) => ({ key: section.key, tag: section.tag !== false })),
		instructions: agent.instructions ?? null,
		cwd: agent.cwd ?? null,
	};
}

/** A registry snapshot as data: what each installed extension brings, and every task definition. */
export function describeRegistry(snapshot: RegistrySnapshot) {
	return {
		extensions: snapshot.installed().map((extension) => ({
			name: extension.name,
			tools: (extension.tools ?? []).map((tool) => ({
				name: tool.name,
				description: tool.description,
				parameters: tool.parameters,
				replay: tool.replay ?? "unsafe",
				executionMode: tool.executionMode ?? null,
				structuredOutputSchema: tool.structuredOutputSchema ?? null,
				callers: tool.callers ?? ["model", "tools"],
				deferred: tool.deferred === true,
			})),
			sections: (extension.sections ?? []).map((section) => ({ key: section.key, tag: section.tag !== false })),
			hooks: (extension.hooks ?? []).map((hook) => hook.task),
			wraps: (extension.wraps ?? []).map((wrap) => ("tool" in wrap ? { tool: wrap.tool } : { section: wrap.section })),
			tasks: (extension.tasks ?? []).map((task) => task.definition.name),
		})),
		tasks: snapshot.tasks().map((task) => ({ name: task.definition.name, version: task.definition.version })),
	};
}

/** Settings as data: extensions by name, every other field as given. */
export function describeSettings(settings: Partial<Settings> & Args) {
	const { extensions, ...rest } = settings;
	return { ...rest, ...(extensions === undefined ? {} : { extensions: extensions.map((extension: Extension) => extension.name) }) };
}

/** `HarnessSettings` resolved over pi-durable's defaults, as `resolveSettings()` does. */
export function resolveSettings(settings: HarnessSettings): Settings {
	return {
		...(settings.extensions === undefined ? {} : { extensions: settings.extensions }),
		stream: { ...settings.stream },
		retry: { ...DEFAULT_RETRY_POLICY, ...settings.retry },
		compaction: { ...DEFAULT_COMPACTION_POLICY, ...settings.compaction },
		progress: {
			partialIntervalMs: settings.progress?.partialIntervalMs ?? DEFAULT_PROGRESS_POLICY.partialIntervalMs,
			outputIntervalMs: settings.progress?.outputIntervalMs ?? DEFAULT_PROGRESS_POLICY.outputIntervalMs,
		},
		toolExecution: settings.toolExecution ?? "parallel",
		steeringMode: settings.steeringMode ?? "one-at-a-time",
		followUpMode: settings.followUpMode ?? "one-at-a-time",
		contextRetentionMs: settings.contextRetentionMs ?? 600_000,
		documentRetentionMs: settings.documentRetentionMs ?? 600_000,
		afterFailedRun: settings.afterFailedRun ?? "keep",
		restartLimit: settings.restartLimit ?? DEFAULT_RESTART_LIMIT,
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
