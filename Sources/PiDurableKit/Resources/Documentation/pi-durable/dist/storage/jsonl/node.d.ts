import type { Context } from "@earendil-works/chord";
import { JsonlStorage, type JsonlStorageOptions } from "./storage.ts";
/** Open or create a JSONL storage directory using the local Node filesystem. */
export declare function openNodeJsonlStorage(directory: string, context: Context, options?: JsonlStorageOptions): Promise<JsonlStorage>;
export { JsonlStorage, type JsonlStorageOptions } from "./storage.ts";
