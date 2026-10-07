import type { ExecutionEnv } from "../env/index.ts";
import type { ToolExecutionApi } from "../harness/types.ts";
/** The call's execution environment; a tool without one fails with an ordinary error result. */
export declare function requireEnv(api: ToolExecutionApi): ExecutionEnv;
