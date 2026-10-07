// Harnesses, conversations, submissions, documents, and task inspection.
import type { Context } from "@earendil-works/chord";
import {
	type ConversationCreateOptions,
	type ConversationInit,
	createRegistry,
	type EntryId,
	type Extension,
	Harness,
	type HarnessSettings,
	MemoryStorage,
	type Storage,
	type SubmissionDraft,
	type SubmissionId,
	type TaskId,
	watchEvents,
	type WatchHandle,
} from "@earendil-works/pi-durable";
import { JsonlStorage } from "@earendil-works/pi-durable/storage/jsonl";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { type Args, emit, finish, host, hostSync, openStream, register, withHandle } from "./core.ts";
import { applyDeep, draftOf, readDoc, retireDoc, watchArguments } from "./docs.ts";
import { SandboxEnv } from "./env.ts";
import { withScope } from "./scopes.ts";
import { HostSqliteDatabase } from "./sqlite.ts";
import { buildExtension } from "./extensions.ts";
import { modelsState } from "./models.ts";
import {
	agentChange,
	conversation,
	describeAgent,
	describeTask,
	type HarnessState,
	harnessState,
	harnesses,
} from "./state.ts";
import { runSwiftCommit, type TxHandle } from "./tx.ts";

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
	};
}

async function openStorage(spec: Args, context: Context): Promise<Storage> {
	switch (spec.kind) {
		case "sqlite":
			return openNodeSqliteStorage(spec.path);
		case "jsonl":
			return JsonlStorage.open("/", new SandboxEnv(spec.path), context, { fsync: spec.fsync === true });
		case "database":
			return SqliteStorage.open(new HostSqliteDatabase(spec.database));
		default:
			return new MemoryStorage();
	}
}

function initializer(state: HarnessState, args: Args, context: Context): ConversationInit | undefined {
	if (args.initialize === undefined || args.initialize === null) return undefined;
	return (tx, conversationId) => runSwiftCommit(tx, state, args.initialize, context, { conversation: conversationId }).then(() => undefined);
}

function createOptions(state: HarnessState, args: Args, context: Context): ConversationCreateOptions {
	return {
		ownership: { kind: "ownerless" },
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
		(end) => finish(stream, end.reason === "listener_error" ? end.error : undefined),
		(error) => finish(stream, error),
	);
}

register({
	"harness.open": async (args, context) => {
		const { models } = modelsState(args.models);
		const registry = createRegistry();
		const state = { id: args.id, registry, settings: { value: args.settings ?? {} } } as HarnessState;
		for (const spec of args.extensions as Args[]) registry.install(buildExtension(state, spec));
		const storage = await openStorage(args.storage, context);
		const environment = args.environment as Args | null | undefined;
		state.harness = await Harness.open(
			storage,
			{
				models,
				registry,
				settings: liveSettings(state),
				...(environment?.root
					? { env: ({ cwd }) => new SandboxEnv(environment.root, cwd ?? "/") }
					: environment?.perConversation
						? {
								// The app picks the environment of each conversation, as pi-durable's `env` function does.
								env: async ({ conversationId, cwd, read }, context) => {
									const chosen = await withScope({ harness: state, reader: read }, (scope) =>
										host<Args | null>(
											"harness.environment",
											{ harness: args.id, handle: scope, conversationId, cwd: cwd ?? null },
											context,
										),
									);
									return chosen === null ? undefined : new SandboxEnv(chosen.root, cwd ?? "/");
								},
							}
						: {}),
				...(args.conversationCreated
					? {
							conversationCreated: (tx, record) =>
								withHandle({ tx, harness: state } satisfies TxHandle, (handle) =>
									host("harness.conversationCreated", { harness: args.id, tx: handle, record }),
								).then(() => undefined),
						}
					: {}),
				...(args.clock ? { now: () => hostSync<number>("harness.now", { harness: args.id }) } : {}),
				onReport: (error) => {
					const message = error instanceof Error ? error.message : String(error);
					if (args.report) void host("harness.report", { harness: args.id, message }).catch(() => undefined);
					else console.warn("pi-durable:", message);
				},
			},
			context,
		);
		harnesses.set(args.id, state);
		if (args.resume !== false) state.harness.resume();
	},
	"harness.close": async (args, context) => {
		const state = harnesses.get(args.harness);
		if (state === undefined) return;
		harnesses.delete(args.harness);
		await state.harness.close(context);
	},
	"harness.resume": (args) => harnessState(args.harness).harness.resume(),
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
	"harness.extensions": (args) => harnessState(args.harness).registry.snapshot().installed().map((extension) => extension.name),
	"harness.waitForIdle": (args, context) => harnessState(args.harness).harness.waitForIdle(context),
	"harness.usage": (args, context) => harnessState(args.harness).harness.usage(context),
	"harness.inspect": async (args, context) => {
		const inspection = await harnessState(args.harness).harness.inspect(context);
		return { ...inspection, tasks: inspection.tasks.map((task) => ({ ...task, record: describeTask(task.record) })) };
	},
	"harness.conversations": async (args, context) => {
		const { harness } = harnessState(args.harness);
		return harness.commit((tx) => tx.scanConversations({}, args.limit ?? 100, args.cursor ?? undefined), context);
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
		return { entries: view.entries, messages: view.messages };
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
			(end) => finish(stream, end.reason === "listener_error" ? end.error : undefined),
			(error) => finish(stream, error),
		);
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
		harnessState(args.harness).harness.abortSubmission(args.submission as SubmissionId, context),

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
