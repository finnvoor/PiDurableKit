import type { SetTimer } from "./types.ts";
/**
 * The default `HarnessOptions.setTimer`: `setTimeout`, waiting out delays beyond its limit in steps. A background timer
 * is unreferenced, so it never keeps the process alive. It is declined in Cloudflare Workers and wherever timers cannot
 * be unreferenced.
 */
export declare const nativeTimer: SetTimer;
/** Timers the Session and Harness arm through the host's `setTimer`. */
export type Timers = {
    /** A timer that paces or resumes work; when the host throws or declines it, `setTimeout` arms it instead. */
    foreground(callback: () => void, delayMs: number): () => void;
    /** A timer that only frees memory; `undefined` when the host declines it. */
    background(callback: () => void, delayMs: number): (() => void) | undefined;
};
/**
 * Wrap a host `setTimer`. A foreground timer must fire, or work stalls: one the host throws on or declines is armed
 * with `setTimeout`, and the first such failure is reported. A background one the host throws on is reported and
 * declined.
 */
export declare function hostTimers(setTimer: SetTimer | undefined, report: (error: unknown) => void): Timers;
