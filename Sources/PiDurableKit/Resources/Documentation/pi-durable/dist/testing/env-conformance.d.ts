import type { EnvConformanceCase, EnvConformanceOptions } from "./types.ts";
/**
 * Creates runner-independent cases for an `ExecutionEnv`. `withEnv` must call and await its callback exactly once per
 * case with an environment whose `cwd` is a fresh, empty, writable directory.
 */
export declare function createEnvConformance(options: EnvConformanceOptions): readonly EnvConformanceCase[];
