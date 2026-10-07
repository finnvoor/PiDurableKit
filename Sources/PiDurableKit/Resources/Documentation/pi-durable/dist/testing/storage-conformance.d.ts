import type { StorageConformanceCase, StorageConformanceOptions } from "./types.ts";
/** Creates runner-independent cases. `withStorage` must call and await its callback exactly once per case. */
export declare function createStorageConformance(options: StorageConformanceOptions): readonly StorageConformanceCase[];
