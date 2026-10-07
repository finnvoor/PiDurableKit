import type { Context } from "@earendil-works/chord";
import type { Cursor, Page } from "../types.ts";
/** Pending waits by key. Each settles once: through `resolve`, `rejectAll`, or cancellation of its context. */
export declare class Waiters<K, T> {
    #private;
    add(key: K, context: Context): Promise<T>;
    keys(): K[];
    resolve(key: K, value: T): void;
    rejectAll(error: unknown): void;
}
/** Every item of a paginated scan, in page order. */
export declare function scanAll<T>(scan: (cursor: Cursor | undefined) => Promise<Page<T, Cursor>>): Promise<T[]>;
export declare function closedError(): Error;
