import type { Id, Seq } from "./types.ts";
/** Apply an erased ID brand at a trusted numeric allocation or decoding boundary. */
export declare function idFromNumber<I extends Id<string>>(value: number): I;
/** Apply the erased commit-sequence brand at a trusted storage boundary. */
export declare function seqFromNumber(value: number): Seq;
