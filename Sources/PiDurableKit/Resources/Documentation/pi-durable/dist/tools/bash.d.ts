import type { Context } from "@earendil-works/chord";
import { type Static, Type } from "typebox";
import type { ToolExecutionApi, ToolRegistration } from "../harness/types.ts";
declare const bashSchema: Type.TObject<{
    command: Type.TString;
    timeout: Type.TOptional<Type.TNumber>;
}>;
declare const powershellSchema: Type.TObject<{
    command: Type.TString;
    timeout: Type.TOptional<Type.TNumber>;
}>;
export type BashToolInput = Static<typeof bashSchema>;
export type PowerShellToolInput = Static<typeof powershellSchema>;
/** A command about to run, which `prepare` may change: the script, its working directory and environment. */
export interface BashExecution {
    command: string;
    cwd: string;
    env: Record<string, string>;
    inheritEnv: boolean;
}
export type BashPrepare = (execution: BashExecution, api: ToolExecutionApi, context: Context) => void | Promise<void>;
export interface BashToolOptions {
    commandPrefix?: string;
    prepare?: BashPrepare;
}
export interface PowerShellToolOptions {
    /** Lines run before each command. */
    commandPrefix?: string;
    prepare?: BashPrepare;
    /** PowerShell programs to try in order; default `pwsh`, then `powershell`. A program that cannot start is skipped. */
    programs?: readonly string[];
}
/**
 * Runs a command through the environment's shell. Its output streams to `api.output()`, where the Harness keeps the
 * tail within the default limits; the result content is that retained output. The retained window goes to the
 * environment, which may omit output outside it and report how much it omitted, so dropped counts stay exact. Output
 * beyond the limits is spilled to a file whose path is reported as a diagnostic. A nonzero exit or timeout throws, which
 * makes an error result that still carries the output and diagnostics.
 */
export declare function createBashTool(options?: BashToolOptions): ToolRegistration<typeof bashSchema>;
/**
 * Runs a PowerShell command, like `bash` but through PowerShell instead of the environment's shell: `pwsh` (PowerShell
 * 7), else Windows PowerShell, started directly with the command as an argument, so no other shell parses it.
 */
export declare function createPowerShellTool(options?: PowerShellToolOptions): ToolRegistration<typeof powershellSchema>;
export {};
