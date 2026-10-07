import type { Context } from "@earendil-works/chord";
import { type BinaryReader, type DirReader, type ExecutionEnv, ExecutionError, FileError, type FileInfo, type FileWatcher, type Result, type ShellExecOptions, type ShellExecResult, type TextLineReader, type WatchChange, type WatchTarget } from "./index.ts";
import { type NodeWatchOptions } from "./node-watch.ts";
export declare class NodeExecutionEnv implements ExecutionEnv {
    /** Every local environment sees the same files. */
    readonly id: string;
    cwd: string;
    private shellPath?;
    private shellEnv?;
    private watchOptions;
    private activeChildPids;
    constructor(options: {
        cwd: string;
        shellPath?: string;
        shellEnv?: NodeJS.ProcessEnv;
        watch?: NodeWatchOptions;
    });
    watch(targets: readonly WatchTarget[], onChange: (change: WatchChange) => void, context: Context): Promise<Result<FileWatcher, FileError>>;
    absolutePath(path: string, _context: Context): Promise<Result<string, FileError>>;
    joinPath(parts: string[], _context: Context): Promise<Result<string, FileError>>;
    exec(command: string | readonly string[], options: ShellExecOptions | undefined, context: Context): Promise<Result<ShellExecResult, ExecutionError>>;
    openTextLineReader(path: string, context: Context): Promise<Result<TextLineReader, FileError>>;
    readTextFile(path: string, context: Context): Promise<Result<string, FileError>>;
    readTextLines(path: string, options: {
        maxLines?: number;
    } | undefined, context: Context): Promise<Result<string[], FileError>>;
    readBinaryFile(path: string, context: Context): Promise<Result<Uint8Array, FileError>>;
    openBinaryReader(path: string, options: {
        noFollow?: boolean;
    } | undefined, context: Context): Promise<Result<BinaryReader, FileError>>;
    writeFile(path: string, content: string | Uint8Array, context: Context): Promise<Result<void, FileError>>;
    appendFile(path: string, content: string | Uint8Array, context: Context): Promise<Result<void, FileError>>;
    truncateFile(path: string, size: number, context: Context): Promise<Result<void, FileError>>;
    flushFile(path: string, context: Context): Promise<Result<void, FileError>>;
    renameFile(sourcePath: string, destinationPath: string, context: Context): Promise<Result<void, FileError>>;
    fileInfo(path: string, context: Context): Promise<Result<FileInfo, FileError>>;
    listDir(path: string, context: Context): Promise<Result<FileInfo[], FileError>>;
    openDirReader(path: string, context: Context): Promise<Result<DirReader, FileError>>;
    canonicalPath(path: string, context: Context): Promise<Result<string, FileError>>;
    exists(path: string, context: Context): Promise<Result<boolean, FileError>>;
    createDir(path: string, options: {
        recursive?: boolean;
    } | undefined, context: Context): Promise<Result<void, FileError>>;
    remove(path: string, options: {
        recursive?: boolean;
        force?: boolean;
    } | undefined, context: Context): Promise<Result<void, FileError>>;
    createTempDir(prefix: string | undefined, context: Context): Promise<Result<string, FileError>>;
    createTempFile(options: {
        prefix?: string;
        suffix?: string;
    } | undefined, context: Context): Promise<Result<string, FileError>>;
    cleanup(_context: Context): Promise<void>;
}
export type { NodeWatchOptions } from "./node-watch.ts";
