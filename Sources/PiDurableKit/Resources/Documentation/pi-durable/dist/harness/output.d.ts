import type { ShellOutputSkip } from "../env/index.ts";
/** Retention limits of one tool's output. */
export type OutputLimits = {
    readonly maxBytes: number;
    readonly maxLines: number;
    readonly retain: "head" | "tail";
};
/** Retained output and what the limits dropped. */
export type BoundedOutput = {
    readonly text: string;
    readonly droppedBytes: number;
    readonly droppedLines: number;
};
/** An exact slice of the input within the limits, and what it left out. */
export type OutputSlice = {
    readonly text: string;
    readonly bytes: number;
    readonly droppedBytes: number;
    readonly droppedLines: number;
};
/** Remove control characters that break display and transcripts; tabs and newlines stay. */
export declare function sanitizeOutput(text: string): string;
/**
 * Bound `text` to whole lines within the limits: the first lines for `head`, the last lines for `tail`. The result is an
 * exact slice, trailing newline included. A single line longer than `maxBytes` is cut at the byte limit on a character
 * boundary.
 */
export declare function boundOutput(text: string, limits: OutputLimits): OutputSlice;
/** The last character boundary at or before `index`. */
export declare function characterEnd(bytes: Uint8Array, index: number): number;
/**
 * Bounded running output of one tool call. Accepting a chunk costs time proportional to the chunk: head retention stops
 * storing once the window is full, and tail retention drops stored text the window no longer needs when it snapshots.
 * Counts of the whole stream are kept so the dropped totals stay exact.
 */
export declare class OutputBuffer {
    #private;
    constructor(limits: OutputLimits);
    /** Bytes currently held; bounded by the limits plus one chunk. */
    get storedBytes(): number;
    /**
     * Accept a chunk; returns whether anything was accepted. `skipped` is output omitted right before the chunk, which
     * must be more than the tail window by at least one byte or line (`ShellOutputInfo.skipped`); only tail retention
     * accepts it.
     */
    push(chunk: string | Uint8Array, skipped?: ShellOutputSkip): boolean;
    /** Flush an incomplete trailing character as a replacement character; call when the stream ends. */
    end(): void;
    /** Retained, sanitized output and what the limits dropped from the whole stream. */
    snapshot(): BoundedOutput;
}
/** Each progress commit also buys a pause proportional to what it wrote. */
export declare const PROGRESS_BYTES_PER_SECOND: number;
/**
 * Adaptive progress commits: the first change after an idle period commits at once; each commit then delays the next
 * by at least `minIntervalMs` and by its written size at 100 KiB/s. At most one commit is in flight; changes made
 * meanwhile coalesce into the next one.
 */
export declare class Progress {
    #private;
    constructor(write: () => Promise<number>, onError: (error: unknown) => void, minIntervalMs: number);
    /** Schedule a commit. */
    mark(): void;
    /** Schedule a commit; the promise settles with the commit that includes this change. */
    markAndWait(): Promise<void>;
    /** Stop committing and wait for the commit in flight; returns the waiters the final commit must settle. */
    stop(): Promise<PromiseWithResolvers<void>[]>;
}
