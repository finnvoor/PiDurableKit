import type { Context } from "@earendil-works/chord";
import { type ClientIdentity } from "@earendil-works/pi-ai/utils/identity";
import type { ReportInfo, Storage } from "../types.ts";
import type { HarnessOptions, Harness as HarnessType, ToolRegistration } from "./types.ts";
/** Key of the Harness's internal index-size getter, for tests. */
export declare const SCHEDULER_INDEX_SIZES: unique symbol;
/** Request identity of a Harness's model requests: pi-ai's defaults with provider attribution to pi. */
export declare const DEFAULT_HARNESS_IDENTITY: ClientIdentity;
/**
 * The host clock, falling back to `Date.now` when it throws: a broken clock must not stop commits. The first throw is
 * reported; the clock is read in every task change, so later ones are not.
 */
export declare function safeNow(now: (() => number) | undefined, report: (error: unknown, info: ReportInfo) => void): () => number;
/** Durable agent harness over one Session. */
export type Harness = HarnessType;
export declare const Harness: {
    /** Open a Harness over storage. The registry may keep changing while the Harness runs. */
    open<Tool extends ToolRegistration>(storage: Storage, options: HarnessOptions<Tool>, context: Context): Promise<Harness>;
};
