import type { Context } from "@earendil-works/chord";
import { type ExecutionEnv } from "../env/index.ts";
export declare function resolveToolPath(env: ExecutionEnv, path: string, context: Context): Promise<string>;
export declare function resolveReadToolPath(env: ExecutionEnv, path: string, context: Context): Promise<string>;
