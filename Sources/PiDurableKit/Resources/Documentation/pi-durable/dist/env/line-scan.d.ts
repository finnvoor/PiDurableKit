import type { LineScan } from "./index.ts";
/**
 * Computes a `LineScan` from a file's bytes fed in order, so an environment can scan any size in bounded memory. Decoded
 * sizes use the same streaming WHATWG decoder as decoding the whole file at once.
 */
export declare class LineScanner {
    #private;
    /** `startLine` and `endLine` must be non-negative integers with `endLine > startLine`; `endLine` absent: to the end. */
    constructor(startLine: number, endLine?: number);
    push(chunk: Uint8Array): void;
    finish(): LineScan;
}
