// Extensions defined in Swift (tools, sections, hooks, wraps, and durable tasks, each calling back into Swift), and
// JavaScript extensions evaluated as they are.
import type { Context } from "@earendil-works/chord";
import {
	CompactionTask,
	type Extension,
	defineExtension,
	defineTask,
	defineTool,
	GenerationTask,
	type HookRegistration,
	hook,
	type PromptSection,
	section,
	ToolTask,
	type ToolRegistration,
	type Wrap,
	wrapSection,
	wrapTool,
} from "@earendil-works/pi-durable";
import { createEditTool, createReadTool, createWriteTool } from "@earendil-works/pi-durable/tools";
import { type Args, handle, host, hostSync, register } from "./core.ts";
import { evaluateExtension } from "./javascript.ts";
import { type Scope, withScope } from "./scopes.ts";
import { describeAgent, describeTask, type HarnessState } from "./state.ts";

type Next = { next: (input?: unknown) => Promise<unknown> };

/** Builds the pi-durable extension for a Swift `Extension.specification`. */
export function buildExtension(state: HarnessState, spec: Args): Extension {
	const name = spec.name as string;
	const base = { harness: state.id, extension: name };

	if (typeof spec.javaScript === "string") return evaluateExtension(spec.javaScript, name, spec.sourceURL ?? undefined);

	if (spec.builtin === "coding") {
		return defineExtension({ name, tools: [createReadTool(), createWriteTool(), createEditTool()] as never });
	}

	const tools: ToolRegistration[] = (spec.tools ?? []).map((tool: Args) =>
		defineTool({
			name: tool.name,
			description: tool.description,
			parameters: tool.parameters,
			...(tool.replay ? { replay: tool.replay } : {}),
			...(tool.executionMode ? { executionMode: tool.executionMode } : {}),
			...(tool.outputLimits ? { outputLimits: tool.outputLimits } : {}),
			...(tool.prepares
				? { prepareArguments: (raw: unknown) => hostSync("tool.prepare", { ...base, tool: tool.name, arguments: raw ?? null }) as never }
				: {}),
			execute: (args, api, context) =>
				withScope({ harness: state, reader: api, tool: api }, (scope) =>
					host<Args | null>(
						"tool.execute",
						{
							...base,
							tool: tool.name,
							handle: scope,
							arguments: args,
							callId: api.callId,
							taskId: api.taskId,
							conversationId: api.conversationId,
						},
						context,
					).then((result) => (result ?? {}) as never),
				),
		}),
	);

	const sections: PromptSection[] = (spec.sections ?? []).map((item: Args) =>
		section(
			item.key,
			async (input, context) => {
				if (typeof item.text === "string") return item.text;
				const rendered = await withScope({ harness: state, reader: input.read }, (scope) =>
					host<string | null>(
						"section.render",
						{
							...base,
							key: item.key,
							handle: scope,
							conversationId: input.conversationId,
							agent: describeAgent(input.agent),
							shown: input.shown,
						},
						context,
					),
				);
				return rendered ?? undefined;
			},
			{ tag: item.tag },
		),
	);

	const flags = (spec.hooks ?? {}) as Record<string, boolean>;
	const hookCall = <T>(method: string, api: Args, extra: Args, context: Context) =>
		withScope({ harness: state, reader: api as never, hook: api as never }, (scope) =>
			host<T | null>(method, { ...base, handle: scope, conversationId: (api as Args).conversationId, taskId: (api as Args).taskId, ...extra }, context),
		).then((result) => result ?? undefined);

	const hooks: HookRegistration[] = [];
	const toolHooks: Args = {};
	if (flags.beforeTool) toolHooks.beforeTool = (call: Args, api: Args, context: Context) => hookCall("hook.beforeTool", api, { call }, context);
	if (flags.afterTool) {
		toolHooks.afterTool = (call: Args, result: Args, api: Args, context: Context) => hookCall("hook.afterTool", api, { call, result }, context);
	}
	if (Object.keys(toolHooks).length > 0) hooks.push(hook(ToolTask, toolHooks));

	const generationHooks: Args = {};
	if (flags.onYield) generationHooks.onYield = (answer: Args, api: Args, context: Context) => hookCall("hook.onYield", api, { answer }, context);
	if (flags.beforeRequest) {
		generationHooks.beforeRequest = (request: Args, api: Args, context: Context) =>
			hookCall("hook.beforeRequest", api, { messages: request.messages }, context);
	}
	if (flags.afterResponse) {
		generationHooks.afterResponse = async (message: Args, api: Args, context: Context) => {
			await hookCall("hook.afterResponse", api, { message }, context);
		};
	}
	if (flags.afterTools) {
		generationHooks.afterTools = async (assistant: number, results: number[], api: Args, context: Context) => {
			await hookCall("hook.afterTools", api, { assistant, results }, context);
		};
	}
	if (Object.keys(generationHooks).length > 0) hooks.push(hook(GenerationTask, generationHooks));

	if (flags.beforeCompact) {
		hooks.push(
			hook(CompactionTask, {
				beforeCompact: (compaction, api, context) =>
					hookCall("hook.beforeCompact", api, { compaction: { ...compaction, instructions: compaction.instructions ?? null } }, context) as never,
			}),
		);
	}

	// Hooks of Swift-defined tasks, which the task runs with `TaskRun.hooks(_:arguments:)`.
	const taskHooks = new Map<string, Args>();
	for (const entry of (spec.taskHooks ?? []) as Args[]) {
		const handlers = taskHooks.get(entry.task) ?? {};
		handlers[entry.name] = (args: unknown, meta: Args | undefined, context?: Context) =>
			host("hook.task", { ...base, task: entry.task, name: entry.name, arguments: args ?? null, conversationId: meta?.conversationId, taskId: meta?.taskId }, context);
		taskHooks.set(entry.task, handlers);
	}
	for (const [task, handlers] of taskHooks) hooks.push(hook({ definition: { name: task } } as never, handlers as never));

	const wraps: Wrap[] = (spec.wraps ?? []).map((wrap: Args) => {
		if (wrap.tool !== undefined) {
			return wrapTool({ name: wrap.tool } as ToolRegistration, (tool) => ({
				...tool,
				execute: (args, api, context) =>
					withScope({ harness: state, reader: api, tool: api, next: (input: unknown) => tool.execute((input ?? args) as never, api, context) }, (scope) =>
						host<Args | null>(
							"wrap.tool",
							{
								...base,
								wrap: wrap.index,
								handle: scope,
								arguments: args,
								callId: api.callId,
								taskId: api.taskId,
								conversationId: api.conversationId,
							},
							context,
						).then((result) => (result ?? {}) as never),
					),
			}));
		}
		return wrapSection(wrap.section, (original) => ({
			...original,
			render: (input, context) =>
				withScope({ harness: state, reader: input.read, next: async () => (await original.render(input, context)) ?? null }, (scope) =>
					host<string | null>(
						"wrap.section",
						{
							...base,
							wrap: wrap.index,
							handle: scope,
							conversationId: input.conversationId,
							agent: describeAgent(input.agent),
							shown: input.shown,
						},
						context,
					),
				).then((text) => text ?? undefined),
		}));
	});

	const tasks = (spec.tasks ?? []).map((task: Args) =>
		defineTask({
			name: task.name,
			version: task.version,
			initial: (input: unknown) => hostSync("task.initial", { ...base, task: task.name, input: input ?? null }) as { phase: string },
			phases: Object.fromEntries(
				(task.phases as string[]).map((phase) => [
					phase,
					(record: Args, runtime: Args, context: Context) =>
						withScope({ harness: state, reader: runtime as never, runtime: runtime as never }, (scope) =>
							host("task.phase", { ...base, task: task.name, phase, handle: scope, record: describeTask(record as never) }, context),
						).then(() => undefined),
				]),
			),
			abort: (record: Args, runtime: Args, context: Context) =>
				withScope({ harness: state, reader: runtime as never, runtime: runtime as never }, (scope) =>
					host("task.abort", { ...base, task: task.name, handle: scope, record: describeTask(record as never) }, context),
				).then(() => undefined),
			...(task.migrates
				? {
						migrate: (input: unknown, checkpoint: unknown, fromVersion: number) =>
							hostSync("task.migrate", { ...base, task: task.name, input, checkpoint, fromVersion }) as never,
					}
				: {}),
		} as never),
	);

	return defineExtension({ name, tools, sections, hooks, wraps, tasks } as never);
}

register({
	"wrap.next": async (args) => (await handle<Scope & Next>(args.handle).next(args.arguments ?? undefined)) ?? null,
	"tool.output": (args) => {
		handle<Scope>(args.handle).tool?.output(args.chunk);
	},
	"tool.details": async (args, context) => {
		await handle<Scope>(args.handle).tool?.details(args.details, context);
	},
	"tool.diagnostic": (args) => {
		handle<Scope>(args.handle).tool?.diagnostic(args.diagnostic);
	},
});
