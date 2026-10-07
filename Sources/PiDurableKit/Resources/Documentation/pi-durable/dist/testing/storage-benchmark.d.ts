import type { ConversationId, DocumentId, EntryId, Seq, Storage } from "../types.ts";
export type StorageBenchmarkScale = {
    readonly name: string;
    readonly entryCount: number;
    readonly taskCount: number;
    readonly documentCount: number;
};
export declare const STORAGE_MEMORY_SCALES: readonly StorageBenchmarkScale[];
export declare const TIMING_SCALE: StorageBenchmarkScale;
declare const REPLAY_TAILS: readonly [0, 16, 128, 1024];
export declare function storageBenchmarkPrimaryRecordCount(scale: StorageBenchmarkScale): number;
export type StorageBenchmarkDataset = {
    readonly firstEntryId: EntryId;
    readonly filteredTaskCount: number;
    readonly exactDocumentId: DocumentId;
    readonly exactDocumentKey: string;
    readonly replayDocumentIds: Readonly<Record<(typeof REPLAY_TAILS)[number], DocumentId>>;
    readonly historicalDocumentId: DocumentId;
    readonly ancientAt: Seq;
    readonly recentAt: Seq;
    readonly deepestConversationId: ConversationId;
    readonly ancestorHeadEntryId: EntryId;
};
/** Seed deterministic representative data through only the public `Storage` contract. */
export declare function seedStorageBenchmark(storage: Storage, scale?: StorageBenchmarkScale): Promise<StorageBenchmarkDataset>;
export type StorageReadBenchmark = {
    readonly name: string;
    run(storage: Storage, dataset: StorageBenchmarkDataset): Promise<number>;
    expected(dataset: StorageBenchmarkDataset): number;
};
export declare const STORAGE_READ_BENCHMARKS: readonly StorageReadBenchmark[];
export type StorageWriteBenchmark = {
    readonly name: string;
    readonly expected: number;
    run(storage: Storage): Promise<number>;
};
/** Seed the common state expected by every write benchmark sample. */
export declare function seedStorageWriteBenchmark(storage: Storage): Promise<void>;
export declare const STORAGE_WRITE_BENCHMARKS: readonly StorageWriteBenchmark[];
export {};
