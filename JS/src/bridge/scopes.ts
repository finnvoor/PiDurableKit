// Invocation scopes: what a Swift tool call, task phase, hook, or section can do while it runs.
import type { Context, JsonValue } from "@earendil-works/chord";
import type {
	ConversationHandle,
	ConversationId,
	DocumentReader,
	EntryId,
	HookApi,
	InputSubmissionDraft,
	JsonObject,
	TaskId,
	TaskRuntime,
	ToolExecutionApi,
} from "@earendil-works/pi-durable";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import { type Args, closeHandle, emit, finish, handle, host, openHandle, openStream, register, watchEndError } from "./core.ts";
import { draftOf, readDoc, watchArguments } from "./docs.ts";
import { describeAgent, describeRegistry, describeSettings, describeTask, type HarnessState, resolveSettings, taskDefinition } from "./state.ts";
import { runSwiftCommit, taskOwnership, traceOptions } from "./tx.ts";

// biome-ignore lint/suspicious/noExplicitAny: task runtimes are erased across Swift-defined tasks
type AnyRuntime = TaskRuntime<any, any, any, any>;

export type Scope = {
	readonly harness: HarnessState;
	readonly reader: DocumentReader;
	readonly tool?: ToolExecutionApi;
	readonly runtime?: AnyRuntime;
	readonly hook?: HookApi;
	/** A section's environment (`PromptInput.env`). */
	readonly env?: ExecutionEnv;
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

/** Timers task phases armed (`TaskRun.timer(after:_:)`), by Swift's ID: each disarms its timer. */
const timers = new Map<number, () => void>();

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
			(end) => finish(args.stream, watchEndError(end as { reason: string; error?: unknown })),
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
	"scope.registry": (args) => {
		const scope = scopeOf(args);
		return describeRegistry((scope.tool?.registry ?? scope.runtime?.registry ?? scope.harness.registry.snapshot()) as never);
	},
	"scope.settings": (args) => {
		const scope = scopeOf(args);
		return describeSettings(scope.runtime?.settings ?? resolveSettings(scope.harness.harnessSettings ?? {}));
	},
	"scope.agent": async (args, context) => describeAgent(await taskOwner(scopeOf(args)).agent(context)),
	"scope.tools": async (args, context) => {
		const agent = await toolOf(scopeOf(args)).agent(context);
		return (args.callable ? agent.callable : agent.tools).map((tool) => ({
			name: tool.name,
			description: tool.description,
			parameters: tool.parameters,
			extension: agent.extensions.find((extension) => extension.tools?.some((candidate) => candidate.name === tool.name))?.name ?? null,
		}));
	},
	/** `api.executeTool()`: a durable nested call of another tool, owned by this one. */
	"scope.executeTool": (args, context) =>
		toolOf(scopeOf(args)).executeTool(args.name, (args.arguments ?? {}) as JsonObject, context, {
			...(args.key == null ? {} : { key: args.key }),
			...(args.progress == null ? {} : { progress: args.progress }),
		}),
	"scope.retainedOutput": (args) => toolOf(scopeOf(args)).retainedOutput(),
	"scope.ownedTasks": async (args, context) => (await runtimeOf(scopeOf(args)).ownedTasks(context)).map(describeTask),
	"scope.abortOwned": (args, context) => runtimeOf(scopeOf(args)).abortOwned(args.task as TaskId, context),
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
				...(args.abandonOnRestart == null ? {} : { abandonOnRestart: args.abandonOnRestart }),
				...traceOptions(args),
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
		return view;
	},
	// The harness clock, for a task phase or a tool call (pi-durable `ToolExecutionApi.now()`).
	"scope.now": (args) => {
		const scope = scopeOf(args);
		return (scope.tool ?? runtimeOf(scope)).now();
	},
	"scope.sleepUntil": (args, context) => runtimeOf(scopeOf(args)).sleepUntil(args.until, args.checkpoint, context),
	"scope.setTimer": (args) => {
		const scope = scopeOf(args);
		const timer = args.timer as number;
		const disarm = runtimeOf(scope).setTimer(() => {
			timers.delete(timer);
			void host("timer.fire", { timer }).catch(() => undefined);
		}, args.delay as number);
		timers.set(timer, disarm);
	},
	"scope.clearTimer": (args) => {
		timers.get(args.timer as number)?.();
		timers.delete(args.timer as number);
	},
	"scope.report": (args) => {
		runtimeOf(scopeOf(args)).report(new Error(args.message), args.from ?? undefined);
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
