import type { StorageConformanceAssertions } from "./types.ts";
export type ExpectLike = (actual: unknown, message?: string) => unknown;
/** Adapts a Vitest/Jest-compatible `expect` function without importing either runner. */
export declare function createExpectAssertions(expect: ExpectLike): StorageConformanceAssertions;
