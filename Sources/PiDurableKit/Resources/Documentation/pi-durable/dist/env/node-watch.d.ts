import type { Context } from "@earendil-works/chord";
import { type FileWatcher, type WatchChange, type WatchTarget } from "./index.ts";
/** How `NodeExecutionEnv` watches. */
export interface NodeWatchOptions {
    /**
     * Force a mode. By default `polling` is chosen on Windows, where native watchers keep directories open and so block
     * renaming their parents, and for file systems that do not report remote changes.
     */
    mode?: "native" | "polling";
    /** Interval between snapshots in `polling` mode; default 2000 ms. */
    pollIntervalMs?: number;
    /** Most directories one watcher covers; default 10,000. */
    maxDirectories?: number;
}
/**
 * Watches by snapshots: native events only trigger a debounced rescan, and changes are the difference between
 * snapshots plus the event paths. A replaced file, a renamed or recreated ancestor, or a directory created with its
 * contents therefore never depends on which events an operating system sends. New directories get their watchers
 * before they are scanned again, so nothing written into them before the watcher existed is missed.
 */
export declare class NodeFileWatcher implements FileWatcher {
    #private;
    private constructor();
    /** Establish coverage: watchers first, then the snapshot later changes are compared with. */
    static open(targets: readonly WatchTarget[], resolvePath: (path: string) => string, onChange: (change: WatchChange) => void, options: NodeWatchOptions): Promise<NodeFileWatcher>;
    get mode(): "native" | "polling";
    close(_context: Context): Promise<void>;
}
