/**
 * Shared truncation utilities for tool outputs.
 *
 * Truncation is based on two independent limits - whichever is hit first wins:
 * - Line limit (default: 2000 lines)
 * - Byte limit (default: 50KB)
 *
 * Never returns partial lines. Tool output streams are bounded by `src/harness/output.ts` instead.
 */
export declare const DEFAULT_MAX_LINES = 2000;
export declare const DEFAULT_MAX_BYTES: number;
export interface TruncationResult {
    /** The truncated content */
    content: string;
    /** Whether truncation occurred */
    truncated: boolean;
    /** Which limit was hit: "lines", "bytes", or null if not truncated */
    truncatedBy: "lines" | "bytes" | null;
    /** Total number of lines in the original content */
    totalLines: number;
    /** Total number of bytes in the original content */
    totalBytes: number;
    /** Number of complete lines in the truncated output */
    outputLines: number;
    /** Number of bytes in the truncated output */
    outputBytes: number;
    /** Whether the last line was partially truncated (only for tail truncation edge case) */
    lastLinePartial: boolean;
    /** Whether the first line exceeded the byte limit (for head truncation) */
    firstLineExceedsLimit: boolean;
    /** The max lines limit that was applied */
    maxLines: number;
    /** The max bytes limit that was applied */
    maxBytes: number;
}
export interface TruncationOptions {
    /** Maximum number of lines (default: 2000) */
    maxLines?: number;
    /** Maximum number of bytes (default: 50KB) */
    maxBytes?: number;
}
export declare function utf8ByteLength(content: string): number;
/**
 * Format bytes as human-readable size.
 */
export declare function formatSize(bytes: number): string;
/**
 * Truncate content from the head (keep first N lines/bytes).
 * Suitable for file reads where you want to see the beginning.
 *
 * Never returns partial lines. If first line exceeds byte limit,
 * returns empty content with firstLineExceedsLimit=true.
 */
export declare function truncateHead(content: string, options?: TruncationOptions): TruncationResult;
/**
 * `truncateHead` of a text known by a prefix and its totals (`lines` counted like `truncateHead`, ignoring a trailing
 * newline). The prefix must be the whole text, or longer than `maxBytes + 1` UTF-8 bytes, or hold at least `maxLines`
 * newlines; then the result equals `truncateHead` of the whole text.
 */
export declare function truncateHeadOf(prefix: string, totals: {
    readonly lines: number;
    readonly bytes: number;
}, options?: TruncationOptions): TruncationResult;
