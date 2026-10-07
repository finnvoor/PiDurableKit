import type { AnyTask, Registry, ToolRegistration } from "./types.ts";
/** Built-in task definitions every registry holds; they are not an extension and cannot be removed or replaced. */
export declare const BUILTIN_TASKS: readonly AnyTask[];
/** Create an application-owned registry holding only the built-in tasks. */
export declare function createRegistry<Tool extends ToolRegistration = ToolRegistration>(): Registry<Tool>;
