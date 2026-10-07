import { type Context } from "@earendil-works/chord";
import type { SessionImpl } from "../session/session.ts";
import type { ConversationId, Storage, SubmissionId, SubmissionRecord, Tx } from "../types.ts";
import { type QueueModes } from "./inbox.ts";
import type { SettledSubmissionRecord, Submission, SubmissionDraft } from "./types.ts";
type AbortResult = "aborted" | "already_placed" | "settled";
/** Admission, waits, and withdrawal of the durable submissions of one Harness. */
export declare class Submissions {
    #private;
    constructor(session: SessionImpl, storage: Storage, now: () => number, queueModes: () => QueueModes, resume: () => void);
    /** Admit a submission in one commit; see `admitSubmission()`. */
    submit(conversationId: ConversationId, draft: SubmissionDraft, context: Context): Promise<Submission>;
    /** Handle for an existing submission, or `undefined`. */
    get(id: SubmissionId, context: Context): Promise<Submission | undefined>;
    status(id: SubmissionId, context: Context): Promise<SubmissionRecord>;
    wait(id: SubmissionId, context: Context): Promise<SettledSubmissionRecord>;
    /** Withdraw a queued submission and remove its inbox item; placed inputs and settled submissions are reported. */
    abort(id: SubmissionId, context: Context, conversationId?: ConversationId): Promise<AbortResult | "not_found">;
}
/**
 * Admit a submission inside a commit (spec §6); `Conversation.submit()` and conversation-owned compactions share it. A
 * known request ID returns its existing submission without writing. A busy conversation queues it in `pi.inbox`, or
 * rejects `whenBusy: "reject"` input with `ConversationBusy`. An idle conversation with queued items queues it behind
 * them and runs a final boundary. Otherwise idle input places a user entry and starts a run, and an idle write appends
 * its entry and settles `done`, or `stale` when its head reaches before the active range.
 */
export declare function admitSubmission(tx: Tx, conversationId: ConversationId, draft: SubmissionDraft, now: number, queueModes: QueueModes): Promise<SubmissionId>;
export {};
