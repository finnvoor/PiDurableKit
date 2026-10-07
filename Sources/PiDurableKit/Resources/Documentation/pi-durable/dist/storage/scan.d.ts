import type { Id, ScanOrder } from "../types.ts";
/** Where a built-in storage scan starts: its order and the last ID a previous page returned. */
export type ScanStart = {
    readonly order: ScanOrder;
    readonly after: number | undefined;
};
/**
 * Resolve a scan's order and position. A cursor continues in the order it was created with, whether the query repeats
 * that order or omits it; a different `order` throws. A cursor without an order, written before scans had one,
 * continues in the scan's default order.
 */
export declare function scanStart(requested: ScanOrder | undefined, cursor: Readonly<Record<string, unknown>> | undefined, fallback: ScanOrder): ScanStart;
/** The continuation of a scan whose last returned item has `id`. */
export declare function nextCursor(id: Id<string>, order: ScanOrder): {
    readonly after: number;
    readonly order: ScanOrder;
};
