// Harnesses, conversations, submissions, documents, and task inspection.
import type { Context } from "@earendil-works/chord";
import {
	AgentDoc,
	InboxDoc,
	LiveDoc,
	ProviderDoc,
	UsageDoc,
	type ConversationCreateOptions,
	type ConversationId,
	type ConversationInit,
	createRegistry,
	type EntryId,
	type Extension,
	Harness,
	type HarnessOptions,
	type HarnessSettings,
	type SubmissionDraft,
	type SubmissionId,
	type TaskId,
	watchEvents,
	type WatchHandle,
} from "@earendil-works/pi-durable";
import { type Args, emit, finish, host, hostSync, openStream, register, serializeError, watchEndError, withHandle } from "./core.ts";
import { applyDeep, draftOf, readDoc, retireDoc, watchArguments } from "./docs.ts";
import { environmentOf } from "./env.ts";
import { withScope } from "./scopes.ts";
import { openStorage } from "./storage.ts";
import { buildExtension } from "./extensions.ts";
import { mergeClientIdentity } from "@earendil-works/pi-ai";
import { clientIdentity } from "../shims/client.ts";
import { modelsState } from "./models.ts";
import { telemetryOf } from "./telemetry.ts";
import {
	agentChange,
	conversation,
	describeAgent,
	describeRegistry,
	describeSettings,
	describeTask,
	type HarnessState,
	harnessState,
	endings,
	harnesses,
	resolveSettings,
} from "./state.ts";
import { conversationOwnership, runSwiftCommit, type TxHandle } from "./tx.ts";

/** Callbacks of timers the app armed for a harness (`HarnessOptions.setTimer`), by ID. */
const hostTimers = new Map<number, () => void>();
let nextHostTimer = 1;

/**
 * `HarnessOptions.setTimer` in Swift: the app arms each timer synchronously, or declines it, and fires it later through
 * `harness.fireTimer`. A throw or a declined foreground timer falls back to `setTimeout`, as pi-durable does.
 */
export function hostTimer(harness: number): NonNullable<HarnessOptions["setTimer"]> {
	return (callback, delayMs, { background }) => {
		const timer = nextHostTimer++;
		hostTimers.set(timer, callback);
		const armed = hostSync<boolean>("harness.setTimer", { harness, timer, delay: delayMs, background });
		if (!armed) {
			hostTimers.delete(timer);
			return undefined;
		}
		return () => {
			if (!hostTimers.delete(timer)) return;
			hostSync("harness.clearTimer", { harness, timer });
		};
	};
}

/** Live settings: every read goes to the newest value Swift sent. */
function liveSettings(state: HarnessState): HarnessSettings {
	const value = () => state.settings.value;
	return {
		get extensions() {
			const names = value().extensions as string[] | undefined;
			if (names === undefined) return undefined;
			const snapshot = state.registry.snapshot();
			return names.map((name) => snapshot.extension(name) ?? ({ name } as Extension));
		},
		get stream() {
			return value().stream;
		},
		get retry() {
			return value().retry;
		},
		get compaction() {
			return value().compaction;
		},
		get progress() {
			return value().progress;
		},
		get toolExecution() {
			return value().toolExecution;
		},
		get steeringMode() {
			return value().steeringMode;
		},
		get followUpMode() {
			return value().followUpMode;
		},
		get contextRetentionMs() {
			return value().contextRetentionMs;
		},
		get afterFailedRun() {
			return value().afterFailedRun;
		},
		get restartLimit() {
			// Swift's `Int.max` means never park.
			const limit = value().restartLimit;
			return typeof limit === "number" && limit >= 9e15 ? Number.POSITIVE_INFINITY : limit;
		},
		get documentRetentionMs() {
			// Swift has no infinite duration: a retention of a million years or more keeps documents.
			const ms = value().documentRetentionMs;
			return typeof ms === "number" && ms >= 3.15e16 ? Number.POSITIVE_INFINITY : ms;
		},
	};
}

function initializer(state: HarnessState, args: Args, context: Context): ConversationInit | undefined {
	if (args.initialize === undefined || args.initialize === null) return undefined;
	return (tx, conversationId) => runSwiftCommit(tx, state, args.initialize, context, { conversation: conversationId }).then(() => undefined);
}

function createOptions(state: HarnessState, args: Args, context: Context): ConversationCreateOptions {
	return {
		ownership: conversationOwnership(args),
		agent: agentChange(state, args.agent),
		init: initializer(state, args, context),
	};
}

/** Streams a pi-durable watch to Swift. */
function pipe<T>(stream: number, watch: WatchHandle<T>, map: (value: T, ops: readonly unknown[]) => unknown = (value) => value): void {
	openStream(stream, () => watch.stop());
	emit(stream, map(watch.value, []));
	watch.start(async (value, ops) => emit(stream, map(value, ops)));
	watch.closed.then(
		(end) => finish(stream, watchEndError(end)),
		(error) => finish(stream, error),
	);
}

register({
	"harness.open": async (args, context) => {
		// The current models, replaceable with `harness.setModels` (pi-durable reads them at each use).
		let models = modelsState(args.models).models;
		const registry = createRegistry();
		const state = { id: args.id, registry, settings: { value: args.settings ?? {} } } as HarnessState;
		for (const spec of args.extensions as Args[]) registry.install(buildExtension(state, spec));
		state.harnessSettings = liveSettings(state);
		const storage = await openStorage(args.storage, context);
		const environment = args.environment as Args | null | undefined;
		if (environment?.perConversation) {
			// The app picks the environment of each conversation, as pi-durable's `env` function does.
			state.env = async ({ conversationId, cwd, read }, context) => {
				const chosen = await withScope({ harness: state, reader: read }, (scope) =>
					host<Args | null>("harness.environment", { harness: args.id, handle: scope, conversationId, cwd: cwd ?? null }, context),
				);
				return chosen === null ? undefined : environmentOf(chosen, cwd);
			};
		} else if (environment != null) {
			state.env = ({ cwd }) => environmentOf(environment, cwd);
		}
		state.setModels = (id) => {
			models = modelsState(id).models;
		};
		state.harness = await Harness.open(
			storage,
			{
				models: () => models,
				registry,
				// The app's identity (`Runtime.Client`), over pi-durable's default attribution to pi, then the harness's own.
				identity: mergeClientIdentity(clientIdentity(), args.identity ?? undefined),
				...(args.telemetry == null ? {} : { telemetry: telemetryOf(args.telemetry) }),
				...(args.timer ? { setTimer: hostTimer(args.id) } : {}),
				...(args.wake
					? {
							onWake: (wake) => {
								void host("harness.wake", { harness: args.id, wake }).catch(() => undefined);
							},
						}
					: {}),
				settings: state.harnessSettings,
				...(state.env === undefined ? {} : { env: state.env }),
				...(args.conversationCreated
					? {
							conversationCreated: (tx, record) =>
								withHandle({ tx, harness: state } satisfies TxHandle, (handle) =>
									host("harness.conversationCreated", { harness: args.id, tx: handle, record }),
								).then(() => undefined),
						}
					: {}),
				...(args.clock ? { now: () => hostSync<number>("harness.now", { harness: args.id }) } : {}),
				onReport: (error, info) => {
					const message = error instanceof Error ? error.message : String(error);
					if (args.report) void host("harness.report", { harness: args.id, message, info: info ?? null }).catch(() => undefined);
					else console.warn("pi-durable:", info?.type ?? "report", message);
				},
			},
			context,
		);
		harnesses.set(args.id, state);
		endings.set(args.id, state.harness.closed);
		if (args.resume !== false) state.harness.resume();
	},
	"harness.close": async (args, context) => {
		const state = harnesses.get(args.harness);
		if (state === undefined) return;
		harnesses.delete(args.harness);
		await state.harness.close(context);
	},
	"harness.resume": (args) => harnessState(args.harness).harness.resume(),
	"harness.wakeState": (args) => harnessState(args.harness).harness.wake(),
	"harness.retryTask": (args, context) => harnessState(args.harness).harness.retryTask(args.task as TaskId, context),
	"harness.setModels": (args) => {
		harnessState(args.harness).setModels?.(args.models);
	},
	/** A timer the app armed for the harness (`timer:`) fired. */
	"harness.fireTimer": (args) => {
		const callback = hostTimers.get(args.timer as number);
		hostTimers.delete(args.timer as number);
		callback?.();
	},
	"harness.setSettings": (args) => {
		harnessState(args.harness).settings.value = args.settings ?? {};
	},
	"harness.install": (args) => {
		const state = harnessState(args.harness);
		state.registry.install(buildExtension(state, args.extension));
	},
	"harness.uninstall": (args) => {
		harnessState(args.harness).registry.uninstall({ name: args.name } as Extension);
	},
	"harness.registry": (args) => describeRegistry(harnessState(args.harness).registry.snapshot()),
	"harness.settings": (args) => {
		const state = harnessState(args.harness);
		return describeSettings(resolveSettings(state.harnessSettings ?? {}));
	},
	"settings.defaults": () => describeSettings(resolveSettings({})),
	"harness.extensions": (args) => harnessState(args.harness).registry.snapshot().installed().map((extension) => extension.name),
	"harness.waitForIdle": (args, context) => harnessState(args.harness).harness.waitForIdle(context),
	"harness.usage": (args, context) => harnessState(args.harness).harness.usage(context),
	"harness.inspect": async (args, context) => {
		const inspection = await harnessState(args.harness).harness.inspect(context);
		return {
			...inspection,
			tasks: inspection.tasks.map((task) => ({
				...task,
				record: describeTask(task.record),
				// A blocked task's migration error is an Error object, which JSON would turn into `{}`.
				state: task.state.kind === "blocked" && task.state.error !== undefined ? { ...task.state, error: serializeError(task.state.error) } : task.state,
			})),
		};
	},
	"harness.conversations": async (args, context) => {
		const { harness } = harnessState(args.harness);
		return harness.commit(
			(tx) =>
				tx.scanConversations(
					{
						...(args.ownerConversation == null ? {} : { ownerConversationId: args.ownerConversation }),
						...(args.ownerTask == null ? {} : { ownerTaskId: args.ownerTask }),
						...(args.order == null ? {} : { order: args.order }),
					},
					args.limit ?? 100,
					args.cursor ?? undefined,
				),
			context,
		);
	},
	"harness.task": async (args, context) => describeTask(await harnessState(args.harness).harness.getTask(args.task as TaskId, context)),
	"harness.waitForTask": async (args, context) =>
		describeTask(await harnessState(args.harness).harness.waitForTask(args.task as TaskId, context)),
	"harness.abortTask": (args, context) => harnessState(args.harness).harness.abortTask(args.task as TaskId, context),
	"harness.commits": (args) => {
		const stream = args.stream as number;
		const unsubscribe = harnessState(args.harness).harness.subscribeCommits((publication) => emit(stream, publication));
		openStream(stream, unsubscribe);
	},
	"harness.taskGraph": async (args, context) => {
		const graph = await harnessState(args.harness).harness.taskGraph(context);
		try {
			return graph.value;
		} finally {
			graph.dispose();
		}
	},
	"harness.watchTaskGraph": async (args, context) => {
		pipe(args.stream, await harnessState(args.harness).harness.watchTaskGraph(context));
	},
	"harness.commit": async (args, context) => {
		const state = harnessState(args.harness);
		const run = (tx: Parameters<Parameters<typeof state.harness.commit>[0]>[0]) => runSwiftCommit(tx, state, args.commit, context);
		if (args.conversation === undefined || args.conversation === null) {
			await state.harness.commit(run, context);
		} else {
			await (await conversation(args, context)).commit(run, context);
		}
	},

	// Conversations

	"conversation.root": async (args, context) => {
		const state = harnessState(args.harness);
		return (await state.harness.root(context, { agent: agentChange(state, args.agent), init: initializer(state, args, context) })).id;
	},
	"conversation.exists": async (args, context) =>
		(await harnessState(args.harness).harness.conversation(args.conversation, context)) !== undefined,
	"conversation.create": async (args, context) => {
		const state = harnessState(args.harness);
		return (await state.harness.createConversation(createOptions(state, args, context), context)).id;
	},
	"conversation.fork": async (args, context) => {
		const state = harnessState(args.harness);
		return (await (await conversation(args, context)).fork(args.at as EntryId, createOptions(state, args, context), context)).id;
	},
	"conversation.record": async (args, context) => {
		const { harness } = harnessState(args.harness);
		return harness.commit((tx) => tx.conversation(args.conversation), context);
	},
	"conversation.agent": async (args, context) => describeAgent(await (await conversation(args, context)).agent(context)),
	"conversation.configure": async (args, context) => {
		const state = harnessState(args.harness);
		await (await conversation(args, context)).configure(agentChange(state, args.change)!, context);
	},
	"conversation.submit": async (args, context) => {
		const submission = await (await conversation(args, context)).submit(args.submission as SubmissionDraft, context);
		return submission.id;
	},
	"conversation.reset": async (args, context) => (await conversation(args, context)).reset(args.handoff ?? undefined, context),
	"conversation.compact": async (args, context) => (await conversation(args, context)).compact(args.instructions ?? undefined, context),
	"conversation.abort": async (args, context) =>
		(await conversation(args, context)).abort(context, { background: args.background === true }),
	"conversation.waitForIdle": async (args, context) => (await conversation(args, context)).waitForIdle(context),
	"conversation.context": async (args, context) => {
		const view = await (await conversation(args, context)).context(context, args.at == null ? undefined : { at: args.at });
		return view;
	},
	"conversation.entries": async (args, context) =>
		(await conversation(args, context)).entries(
			{
				...(args.minEntryId == null ? {} : { minEntryId: args.minEntryId }),
				...(args.maxEntryId == null ? {} : { maxEntryId: args.maxEntryId }),
				...(args.order == null ? {} : { order: args.order }),
			},
			args.limit ?? 50,
			args.cursor ?? undefined,
			context,
		),
	"conversation.entry": async (args, context) =>
		(await (await conversation(args, context)).commit((tx) => tx.entry(args.entry as EntryId), context)) ?? null,
	"conversation.view": async (args, context) => {
		const view = await (await conversation(args, context)).viewState(context);
		try {
			return view.value;
		} finally {
			view.dispose();
		}
	},
	"conversation.watch": async (args, context) => {
		// Entries are immutable, so after the first view only the entries appended since are sent (with how many of the
		// previous ones to keep); a long transcript then costs nothing per update. A reset or compaction resends all.
		let sent: readonly { id: unknown }[] | undefined;
		pipe(args.stream, await (await conversation(args, context)).watch(context), (value) => {
			const { entries, ...rest } = value as unknown as { entries: readonly { id: unknown }[] };
			const previous = sent;
			sent = entries;
			if (previous !== undefined && previous.length <= entries.length) {
				let same = true;
				for (let index = 0; index < previous.length; index++) {
					if (previous[index]!.id !== entries[index]!.id) {
						same = false;
						break;
					}
				}
				if (same) return { ...rest, keep: previous.length, append: entries.slice(previous.length) };
			}
			return { ...rest, entries };
		});
	},
	"conversation.changes": async (args, context) => {
		pipe(args.stream, await (await conversation(args, context)).watch(context), (view, ops) => ({ view, ops }));
	},
	"conversation.events": async (args, context) => {
		const stream = args.stream as number;
		const events = await watchEvents(harnessState(args.harness).harness, args.conversation, context);
		openStream(stream, () => events.stop());
		emit(stream, [events.snapshot]);
		events.start(async (batch) => emit(stream, batch));
		events.closed.then(
			(end) => finish(stream, watchEndError(end)),
			(error) => finish(stream, error),
		);
	},

	/** A built-in conversation document: `pi.agent` (optionally as of an entry), `pi.live`, `pi.inbox`, `pi.usage`, `pi.provider`. */
	"conversation.builtinDoc": async (args, context) => {
		const { harness } = harnessState(args.harness);
		const id = args.conversation as ConversationId;
		switch (args.doc) {
			case "pi.agent":
				return (
					(args.asOf == null
						? await harness.snapshot(AgentDoc, id, context)
						: await harness.snapshotAsOf(AgentDoc, id, args.asOf as EntryId, context)) ?? null
				);
			case "pi.live":
				return (await harness.snapshot(LiveDoc, id, context)) ?? null;
			case "pi.inbox":
				return (await harness.snapshot(InboxDoc, id, context)) ?? null;
			case "pi.usage":
				return (await harness.snapshot(UsageDoc, id, context)) ?? null;
			case "pi.provider":
				return (await harness.snapshot(ProviderDoc, id, context)) ?? null;
			default:
				throw Object.assign(new Error(`Unknown built-in document ${args.doc}`), { name: "NotFound" });
		}
	},

	// Submissions

	"submission.status": async (args, context) => {
		const submission = await harnessState(args.harness).harness.submission(args.submission as SubmissionId, context);
		return submission === undefined ? null : submission.status(context);
	},
	"submission.wait": async (args, context) => {
		const submission = await harnessState(args.harness).harness.submission(args.submission as SubmissionId, context);
		if (submission === undefined) throw Object.assign(new Error(`Submission ${args.submission} does not exist`), { name: "NotFound" });
		return submission.wait(context);
	},
	"submission.abort": async (args, context) =>
		harnessState(args.harness).harness.abortSubmission(
			args.submission as SubmissionId,
			context,
			args.conversation == null ? undefined : (args.conversation as ConversationId),
		),

	// Documents

	"doc.read": (args, context) => readDoc(harnessState(args.harness).harness, args, context),
	"doc.update": async (args, context) => {
		const state = harnessState(args.harness);
		let next: unknown;
		await state.harness.commit(async (tx) => {
			const draft = await draftOf(tx, args);
			next = await host("doc.mutate", { mutation: args.mutation, value: JSON.parse(JSON.stringify(draft)) }, context);
			applyDeep(draft, next as Record<string, unknown>);
		}, context);
		return next;
	},
	"doc.retire": async (args, context) => {
		await harnessState(args.harness).harness.commit((tx) => retireDoc(tx, args), context);
	},
	"doc.watch": async (args, context) => {
		const state = harnessState(args.harness);
		const watchDoc = (state.harness.watchDoc as (...rest: unknown[]) => ReturnType<typeof state.harness.watchDoc>).bind(state.harness);
		let watch = await watchDoc(...watchArguments(args), context);
		if (watch === undefined) {
			// Only existing documents can be watched: create it with its initial value first.
			await state.harness.commit(async (tx) => {
				await draftOf(tx, args);
			}, context);
			watch = await watchDoc(...watchArguments(args), context);
			if (watch === undefined) throw new Error(`Document ${args.doc.kind} cannot be watched`);
		}
		pipe(args.stream, watch, (value) => value ?? args.doc.initial);
	},
});
