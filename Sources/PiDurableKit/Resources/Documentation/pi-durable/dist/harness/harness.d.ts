import type { Context } from "@earendil-works/chord";
import type { Storage } from "../types.ts";
import type { HarnessOptions, Harness as HarnessType, ToolRegistration } from "./types.ts";
/** Durable agent harness over one Session. */
export type Harness = HarnessType;
export declare const Harness: {
    /** Open a Harness over storage. The registry may keep changing while the Harness runs. */
    open<Tool extends ToolRegistration>(storage: Storage, options: HarnessOptions<Tool>, context: Context): Promise<Harness>;
};
