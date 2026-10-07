import { type ExpectLike } from "./assertions.ts";
import type { EnvConformanceOptions, EnvConformanceProvider, StorageConformanceProvider } from "./types.ts";
export interface StorageConformanceRunner {
    readonly describe: (name: string, suite: () => void) => unknown;
    readonly expect: ExpectLike;
    readonly it: (name: string, test: () => Promise<void>, timeoutMs?: number) => unknown;
}
/** Registers the runner-independent cases with a Vitest/Jest-compatible test runner. */
export declare function registerStorageConformance(runner: StorageConformanceRunner, name: string, withStorage: StorageConformanceProvider): void;
/** Registers the runner-independent `ExecutionEnv` cases with a Vitest/Jest-compatible test runner. */
export declare function registerEnvConformance(runner: StorageConformanceRunner, name: string, withEnv: EnvConformanceProvider, options?: Pick<EnvConformanceOptions, "shell" | "symlinks">): void;
