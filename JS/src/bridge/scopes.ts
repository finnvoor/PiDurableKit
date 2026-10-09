// Invocation scopes: what a Swift tool call, task phase, hook, or section can do while it runs.
import type { Context, JsonValue } from "@earendil-works/chord";
import type {
	ConversationHandle,
	ConversationId,
	DocumentReader,
	EntryId,
	HookApi,
	InputSubmissionDraft,
	TaskId,
	TaskRuntime,
	ToolExecutionApi,
} from "@earendil-works/pi-durable";
import { validateToolArguments } from "@earendil-works/pi-ai/utils/validation";
import { type Args, closeHandle, emit, finish, handle, host, openHandle, openStream, register } from "./core.ts";
import { draftOf, readDoc, watchArguments } from "./docs.ts";
import { describeAgent, describeTask, type HarnessState, taskDefinition } from "./state.ts";
import { runSwiftCommit, taskOwnership } from "./tx.ts";

// biome-ignore lint/suspicious/noExplicitAny: task runtimes are erased across Swift-defined tasks
type AnyRuntime = TaskRuntime<any, any, any, any>;

export type Scope = {
	readonly harness: HarnessState;
	readonly reader: DocumentReader;
	readonly tool?: ToolExecutionApi;
	readonly runtime?: AnyRuntime;
	readonly hook?: HookApi;
	readonly children: number[];
};

/** Opens a scope handle for the duration of `body`; handles it hands out close with it. */
export async function withScope<T>(
	scope: Omit<Scope, "children"> & Record<string, unknown>,
	body: (handle: number) => Promise<T>,
): Promise<T> {
	const value = { ...scope, children: [] } as Scope;
	const id = openHandle(value);
	try {
		return await body(id);
	} finally {
		closeHandle(id);
		for (const child of value.children) closeHandle(child);
	}
}

function scopeOf(args: Args): Scope {
	return handle<Scope>(args.handle);
}

function memoOwner(scope: Scope): Pick<HookApi, "memo"> {
	const owner = scope.tool ?? scope.runtime ?? scope.hook;
	if (owner === undefined) throw new Error("Memos are not available here");
	return owner as Pick<HookApi, "memo">;
}

function taskOwner(scope: Scope): Pick<AnyRuntime, "getTask" | "waitForTask" | "agent" | "conversation"> {
	const owner = scope.tool ?? scope.runtime;
	if (owner === undefined) throw new Error("Only tool calls and task phases can do this");
	return owner as Pick<AnyRuntime, "getTask" | "waitForTask" | "agent" | "conversation">;
}

function toolOf(scope: Scope): ToolExecutionApi {
	if (scope.tool === undefined) throw new Error("Only tool calls can do this");
	return scope.tool;
}

function errorText(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

/** A result for a call that could not run, as the harness records one. */
function failed(code: string, error: unknown) {
	return { content: [], isError: true, diagnostics: [{ severity: "error", code, message: errorText(error) }] };
}

/**
 * Runs a tool the calling conversation is offered as the harness runs a tool call: repairs and validates the arguments,
 * then calls `execute()` with the calling tool's `api`. What the called tool reports (output, details, diagnostics)
 * goes into its own result instead of the caller's.
 */
async function callTool(api: ToolExecutionApi, name: string, raw: unknown, context: Context) {
	const agent = await api.agent(context);
	const tool = agent.tools.find((candidate) => candidate.name === name);
	if (tool === undefined) throw new Error(`Tool ${name} is not offered to this conversation`);
	let args: unknown;
	try {
		const prepared = tool.prepareArguments === undefined ? raw : tool.prepareArguments(raw);
		args = validateToolArguments(tool, { type: "toolCall", id: api.callId, name, arguments: prepared as Args });
	} catch (error) {
		return failed("invalid_arguments", error);
	}
	const output: string[] = [];
	const diagnostics: unknown[] = [];
	let details: JsonValue | undefined;
	const decoder = new TextDecoder();
	const reporting = {
		...api,
		output: (chunk: string | Uint8Array) => {
			output.push(typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true }));
		},
		outputWindow: undefined,
		diagnostic: (diagnostic: unknown) => {
			diagnostics.push(diagnostic);
		},
		details: async (value: JsonValue) => {
			details = value;
		},
	} as ToolExecutionApi;
	let result: Args;
	try {
		result = (await tool.execute(args as never, reporting, context)) as Args;
	} catch (error) {
		if (context.abortSignal?.aborted) throw error;
		return failed("tool_error", error);
	}
	const streamed = output.join("") + decoder.decode();
	return {
		...result,
		content: result.content ?? (streamed === "" ? [] : [{ type: "text", text: streamed }]),
		...(result.details === undefined && details !== undefined ? { details } : {}),
		diagnostics: [...diagnostics, ...(result.diagnostics ?? [])],
	};
}

function runtimeOf(scope: Scope): AnyRuntime {
	if (scope.runtime === undefined) throw new Error("Only task phases can do this");
	return scope.runtime;
}

register({
	"scope.read": (args, context) => readDoc(scopeOf(args).reader, args, context),
	"scope.watchDoc": async (args, context) => {
		const scope = scopeOf(args);
		const observer = scope.tool ?? scope.runtime;
		if (observer === undefined) throw new Error("Only tool calls and task phases can watch documents");
		type Watch = (...rest: unknown[]) => Promise<
			{ value: unknown; start(listener: (value: unknown) => Promise<void>): void; stop(): Promise<unknown>; closed: Promise<unknown> } | undefined
		>;
		const watch = (observer.watchDoc as unknown as Watch).bind(observer);
		let handle = await watch(...watchArguments(args), context);
		if (handle === undefined) {
			// Only existing documents can be watched: create it with its initial value first.
			const create = async (tx: Parameters<typeof draftOf>[0]) => {
				await draftOf(tx, args);
				return undefined;
			};
			await (observer.commit as (change: unknown, context: unknown) => Promise<unknown>)(create, context);
			handle = await watch(...watchArguments(args), context);
			if (handle === undefined) throw new Error(`Document ${args.doc.kind} cannot be watched`);
		}
		const watchHandle = handle;
		openStream(args.stream, () => watchHandle.stop());
		emit(args.stream, watchHandle.value ?? args.doc.initial);
		watchHandle.start(async (value) => emit(args.stream, value ?? args.doc.initial));
		watchHandle.closed.then(
			() => finish(args.stream),
			(error) => finish(args.stream, error),
		);
	},
	"scope.memo": async (args, context) => {
		const owner = memoOwner(scopeOf(args));
		const value =
			args.candidate === undefined
				? await owner.memo<JsonValue>(args.name, context)
				: await owner.memo<JsonValue>(args.name, args.candidate as JsonValue, context);
		return value ?? null;
	},
	"scope.agent": async (args, context) => describeAgent(await taskOwner(scopeOf(args)).agent(context)),
	"scope.tools": async (args, context) => {
		const agent = await toolOf(scopeOf(args)).agent(context);
		return agent.tools.map((tool) => ({
			name: tool.name,
			description: tool.description,
			parameters: tool.parameters,
			extension: agent.extensions.find((extension) => extension.tools?.some((candidate) => candidate.name === tool.name))?.name ?? null,
		}));
	},
	"scope.callTool": (args, context) => callTool(toolOf(scopeOf(args)), args.name, args.arguments ?? {}, context),
	"scope.getTask": async (args, context) => describeTask(await taskOwner(scopeOf(args)).getTask(args.task as TaskId, context)),
	"scope.waitForTask": async (args, context) => describeTask(await taskOwner(scopeOf(args)).waitForTask(args.task as TaskId, context)),
	"scope.conversation": async (args, context) => {
		const scope = scopeOf(args);
		const found = await taskOwner(scope).conversation(args.conversation as ConversationId, context);
		if (found === undefined) return null;
		const id = openHandle(found);
		scope.children.push(id);
		return id;
	},
	"scope.commit": async (args, context) => {
		const scope = scopeOf(args);
		if (scope.runtime !== undefined) {
			await scope.runtime.commit(
				async (tx, current) =>
					((await runSwiftCommit(tx, scope.harness, args.commit, context, { current: describeTask(current) })) ?? undefined) as never,
				context,
			);
			return null;
		}
		if (scope.tool === undefined) throw new Error("Only tool calls and task phases can commit");
		await scope.tool.commit((tx) => runSwiftCommit(tx, scope.harness, args.commit, context), context);
		return null;
	},
	"scope.createTask": async (args, context) => {
		const scope = scopeOf(args);
		if (scope.tool === undefined) throw new Error("Use a commit to create tasks here");
		return scope.tool.createTask(
			taskDefinition(scope.harness, args.task) as never,
			args.input,
			{
				// A tool's tasks belong to its call unless they are top-level work of the conversation.
				ownership: args.ownedByConversation ? { kind: "conversation" } : taskOwnership({ ownerTask: scope.tool.taskId }),
				...(args.background ? { background: true } : {}),
			},
			context,
		);
	},
	"scope.hooks": async (args, context) => {
		const runtime = runtimeOf(scopeOf(args));
		const results: unknown[] = [];
		await runtime.hooks.each(args.name, async (handler: (...rest: unknown[]) => unknown) => {
			results.push((await handler(args.arguments, { conversationId: runtime.conversationId, taskId: runtime.taskId }, context)) ?? null);
		});
		return results;
	},
	"scope.outcomes": (args, context) => runtimeOf(scopeOf(args)).outcomes(args.tasks as TaskId[], context),
	"scope.entry": async (args, context) => (await runtimeOf(scopeOf(args)).entry(args.entry as EntryId, context)) ?? null,
	"scope.context": async (args, context) => {
		const view = await runtimeOf(scopeOf(args)).context(args.conversation as ConversationId, context, {
			...(args.at == null ? {} : { at: args.at as EntryId }),
		});
		return { entries: view.entries, messages: view.messages };
	},
	"scope.now": (args) => runtimeOf(scopeOf(args)).now(),
	"scope.sleep": (args, context) => runtimeOf(scopeOf(args)).sleep(args.until, context),
	"scope.report": (args) => {
		runtimeOf(scopeOf(args)).report(new Error(args.message));
	},

	// Conversation handles (invocation-bound)

	"conversationHandle.submit": async (args, context) =>
		(await handle<ConversationHandle>(args.handle).submit(args.submission as InputSubmissionDraft, context)).id,
	"conversationHandle.abort": (args, context) =>
		handle<ConversationHandle>(args.handle).abort(context, { background: args.background === true }),
	"conversationHandle.waitForIdle": (args, context) => handle<ConversationHandle>(args.handle).waitForIdle(context),
});

/** The fields every Swift scope call carries. */
export function scopeArguments(harness: HarnessState, extension: string, scopeHandle: number, extra: Args): Args {
	return { harness: harness.id, extension, handle: scopeHandle, ...extra };
}

export { host };
