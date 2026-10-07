import { type Static, Type } from "typebox";
import type { ToolRegistration } from "../harness/types.ts";
import { type TruncationResult } from "../truncate.ts";
declare const readSchema: Type.TObject<{
    path: Type.TString;
    offset: Type.TOptional<Type.TNumber>;
    limit: Type.TOptional<Type.TNumber>;
}>;
export type ReadToolInput = Static<typeof readSchema>;
export type ReadToolDetails = {
    /** How the shown text was cut; the text itself is the result content. */
    truncation?: Omit<TruncationResult, "content">;
};
/** Reads text files. Remarks about truncation and continuation are diagnostics; the content is only file text. */
export declare function createReadTool(): ToolRegistration<typeof readSchema, ReadToolDetails>;
export {};
