import { type Static, Type } from "typebox";
import type { ToolRegistration } from "../harness/types.ts";
declare const editSchema: Type.TObject<{
    path: Type.TString;
    edits: Type.TArray<Type.TObject<{
        oldText: Type.TString;
        newText: Type.TString;
    }>>;
}>;
export type EditToolInput = Static<typeof editSchema>;
export type EditToolDetails = {
    diff: string;
    patch: string;
    firstChangedLine?: number;
};
export declare function createEditTool(): ToolRegistration<typeof editSchema, EditToolDetails>;
export {};
