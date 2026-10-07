import type { Context } from "@earendil-works/chord";
import { type ExecutionEnv } from "../env/index.ts";
/**
 * Serialize `edit` and `write` mutations of one file within this process: same file system id and canonical path,
 * whichever environment object the call got. Other files, and other file systems, never wait. Concurrent calls on one
 * file run in the order their keys resolve. Not a lock against `bash` or other processes.
 */
export declare function withFileMutationQueue<T>(env: ExecutionEnv, path: string, fn: () => Promise<T>, context: Context): Promise<T>;
