import { type Static, Type } from "typebox";
import type { ToolRegistration } from "../harness/types.ts";
declare const writeSchema: Type.TObject<{
    path: Type.TString;
    content: Type.TString;
}>;
export type WriteToolInput = Static<typeof writeSchema>;
export declare function createWriteTool(): ToolRegistration<typeof writeSchema>;
export {};
