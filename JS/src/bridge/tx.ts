// Transactions: Swift runs a closure inside a pi-durable commit and reaches the `Tx` through a handle.
import type { Context } from "@earendil-works/chord";
import {
	type ConversationId,
	type ConversationOwnership,
	configure,
	type Cursor,
	type EntryDraft,
	type EntryId,
	type TaskId,
	type TaskOwnership,
	type Tx,
} from "@earendil-works/pi-durable";
import { type Args, handle, host, register, withHandle } from "./core.ts";
import { applyDeep, draftOf, retireDoc } from "./docs.ts";
import { agentChange, describeTask, type HarnessState, taskDefinition } from "./state.ts";

export type TxHandle = { tx: Tx; harness: HarnessState };

/** Runs the Swift commit closure `commit` against `tx`. */
export function runSwiftCommit(tx: Tx, harness: HarnessState, commit: number, context: Context, extra: Args = {}): Promise<unknown> {
	return withHandle({ tx, harness } satisfies TxHandle, (id) => host("commit.run", { commit, tx: id, ...extra }, context));
}

function txOf(args: Args): TxHandle {
	return handle<TxHandle>(args.handle);
}

function conversationOwnership(args: Args): ConversationOwnership {
	return args.ownerTask === undefined || args.ownerTask === null ? { kind: "ownerless" } : { kind: "task", taskId: args.ownerTask as TaskId };
}

export function taskOwnership(args: Args): TaskOwnership {
	return args.ownerTask === undefined || args.ownerTask === null ? { kind: "conversation" } : { kind: "task", taskId: args.ownerTask as TaskId };
}

register({
	"tx.conversation": async (args) => (await txOf(args).tx.conversation(args.conversation as ConversationId)) ?? null,
	"tx.entry": async (args) => (await txOf(args).tx.entry(args.entry as EntryId)) ?? null,
	"tx.task": async (args) => describeTask(await txOf(args).tx.task(args.task as TaskId)),
	"tx.scanConversations": (args) =>
		txOf(args).tx.scanConversations(
			{
				...(args.ownerConversation == null ? {} : { ownerConversationId: args.ownerConversation }),
				...(args.ownerTask == null ? {} : { ownerTaskId: args.ownerTask }),
				...(args.order == null ? {} : { order: args.order }),
			},
			args.limit ?? 100,
			(args.cursor ?? undefined) as Cursor | undefined,
		),
	"tx.scanEntries": (args) =>
		txOf(args).tx.scanEntries(
			{
				conversationId: args.conversation,
				...(args.minEntryId == null ? {} : { minEntryId: args.minEntryId }),
				...(args.maxEntryId == null ? {} : { maxEntryId: args.maxEntryId }),
				...(args.order == null ? {} : { order: args.order }),
			},
			args.limit ?? 50,
			(args.cursor ?? undefined) as Cursor | undefined,
		),
	"tx.scanTasks": async (args) => {
		const page = await txOf(args).tx.scanTasks(args.query ?? {}, args.limit ?? 100, (args.cursor ?? undefined) as Cursor | undefined);
		return { items: page.items.map(describeTask), next: page.next };
	},
	"tx.createConversation": (args) => txOf(args).tx.createConversation({ ownership: conversationOwnership(args) }),
	"tx.forkConversation": (args) =>
		txOf(args).tx.forkConversation(args.conversation, args.at, { ownership: conversationOwnership(args) }),
	"tx.appendEntry": (args) => txOf(args).tx.appendEntry(args.conversation, args.entry as EntryDraft),
	"tx.createTask": (args) => {
		const { tx, harness } = txOf(args);
		return tx.createTask(taskDefinition(harness, args.task) as never, args.input, {
			ownership: taskOwnership(args),
			...(args.conversation == null ? {} : { conversationId: args.conversation }),
			...(args.background ? { background: true } : {}),
		});
	},
	"tx.readDoc": async (args) => JSON.parse(JSON.stringify(await draftOf(txOf(args).tx, args))),
	"tx.writeDoc": async (args) => {
		applyDeep(await draftOf(txOf(args).tx, args), args.value);
	},
	"tx.retireDoc": (args) => retireDoc(txOf(args).tx, args),
	"tx.configure": async (args) => {
		const { tx, harness } = txOf(args);
		await configure(tx, args.conversation, agentChange(harness, args.change)!);
	},
});
