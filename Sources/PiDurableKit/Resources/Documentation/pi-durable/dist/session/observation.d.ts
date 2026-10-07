import type { Context, ReplicatedStateSource, ReplicatedStateSourceAttachment } from "@earendil-works/chord";
import type { Op } from "@earendil-works/chord/delta";
import type { JsonObject, WatchEnd, WatchHandle } from "../types.ts";
export type ObservedDocumentValue = Readonly<JsonObject> | null;
/** Canonical terminal update for a retired document incarnation. */
export declare const RETIREMENT_OPERATIONS: readonly Op[];
/**
 * Session-to-Chord bridge owned one-to-one by one attached state: a document, or a conversation view. A `null` value
 * retires it. @internal
 */
export declare class CommittedStateSource<T = ObservedDocumentValue> implements ReplicatedStateSource<T> {
    #private;
    constructor(value: T, release: () => void);
    attach(): ReplicatedStateSourceAttachment<T>;
    advance(value: T, ops: readonly Op[], context: Context): void;
    closeSession(): void;
}
/**
 * Serialized exact-frame watch bound to one document incarnation or conversation view. A `null` value retires it.
 * @internal
 */
export declare class CommittedWatch<T = ObservedDocumentValue> implements WatchHandle<T> {
    #private;
    /** `replace` gives the value an overflow delivers; by default the newest value. */
    constructor(value: T, detach: () => void, replace?: () => T);
    get value(): T;
    get closed(): Promise<WatchEnd>;
    start(listener: (value: T, ops: readonly Op[], context: Context) => Promise<void>): void;
    stop(): Promise<WatchEnd>;
    observeCancellation(signal: AbortSignal): void;
    cancel(): void;
    closeSession(): void;
    advance(value: T, ops: readonly Op[], context: Context): void;
}
