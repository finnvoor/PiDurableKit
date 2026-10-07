// A sandboxed execution environment: a virtual file system rooted at one host directory, for pi-durable's
// read/write/edit tools and JSONL storage. Paths are virtual and absolute (`/notes/todo.md`), so the model never sees
// the app's container paths and cannot leave the directory. There is no shell on iOS: `exec` fails.
import type { Context } from "@earendil-works/chord";
import {
	type BinaryReader,
	type DirReader,
	ExecutionError,
	type ExecutionEnv,
	err,
	FileError,
	type FileErrorCode,
	type FileInfo,
	type FileWatcher,
	LineScanner,
	type LineScan,
	ok,
	type Result,
	type ShellExecResult,
	type TextLine,
	type TextLineReader,
} from "@earendil-works/pi-durable/env";
import { native } from "../runtime/native.ts";

type NativeInfo = { name: string; kind: "file" | "directory" | "symlink"; size: number; mtimeMs: number };

const encoder = new TextEncoder();

/** Normalizes a virtual path against `cwd`; `..` never climbs above the root. */
export function normalize(path: string, cwd = "/"): string {
	const parts: string[] = [];
	for (const part of (path.startsWith("/") ? path : `${cwd}/${path}`).split("/")) {
		if (part === "" || part === ".") continue;
		if (part === "..") parts.pop();
		else parts.push(part);
	}
	return `/${parts.join("/")}`;
}

/** A FileError for `path`, with host paths under `root` shown as sandbox paths. */
function fileError(error: unknown, path: string, root: string): FileError {
	const code = ((error as { code?: string }).code ?? "unknown") as FileErrorCode;
	const message = (error instanceof Error ? error.message : String(error)).replaceAll(root, "");
	return new FileError(code, message, path);
}

function aborted(context: Context, path: string): Result<never, FileError> | undefined {
	return context.abortSignal?.aborted ? err(new FileError("aborted", "Operation aborted", path)) : undefined;
}

export class SandboxEnv implements ExecutionEnv {
	readonly id: string;
	cwd: string;
	readonly #root: string;
	#temp = 0;

	/** - Parameter root: the host directory that is `/` in the sandbox. */
	constructor(root: string, cwd = "/") {
		this.#root = root.replace(/\/+$/, "");
		this.id = `sandbox:${this.#root}`;
		this.cwd = normalize(cwd);
	}

	#real(path: string): string {
		return this.#root + normalize(path, this.cwd);
	}

	#virtual(real: string): string | undefined {
		if (real === this.#root) return "/";
		return real.startsWith(`${this.#root}/`) ? real.slice(this.#root.length) : undefined;
	}

	#run<T>(path: string, context: Context, body: (real: string) => T): Result<T, FileError> {
		const stop = aborted(context, path);
		if (stop) return stop;
		try {
			return ok(body(this.#real(path)));
		} catch (error) {
			return err(fileError(error, normalize(path, this.cwd), this.#root));
		}
	}

	#info(path: string, real: string, follow = true): FileInfo {
		const info = JSON.parse(native.fsStat(real, follow)) as NativeInfo;
		return { name: normalize(path, this.cwd).split("/").pop() || "/", path: normalize(path, this.cwd), kind: info.kind, size: info.size, mtimeMs: info.mtimeMs };
	}

	async absolutePath(path: string): Promise<Result<string, FileError>> {
		return ok(normalize(path, this.cwd));
	}

	async joinPath(parts: string[]): Promise<Result<string, FileError>> {
		return ok(normalize(parts.join("/"), "/"));
	}

	async readTextFile(path: string, context: Context): Promise<Result<string, FileError>> {
		return this.#run(path, context, (real) => new TextDecoder().decode(native.fsReadFile(real)));
	}

	async readTextLines(path: string, options: { maxLines?: number } | undefined, context: Context): Promise<Result<string[], FileError>> {
		const text = await this.readTextFile(path, context);
		if (!text.ok) return text;
		const lines = text.value.split(/\r?\n/);
		if (lines.at(-1) === "") lines.pop();
		return ok(options?.maxLines === undefined ? lines : lines.slice(0, options.maxLines));
	}

	async openTextLineReader(path: string, context: Context): Promise<Result<TextLineReader, FileError>> {
		const text = await this.readTextFile(path, context);
		if (!text.ok) return text;
		const pieces = text.value.split("\n");
		let index = 0;
		return ok({
			readLine: async (): Promise<Result<TextLine | undefined, FileError>> => {
				while (index < pieces.length) {
					const terminated = index < pieces.length - 1;
					const value = pieces[index++]!;
					if (!terminated && value === "") return ok(undefined);
					return ok({ text: value.replace(/\r$/, ""), terminated });
				}
				return ok(undefined);
			},
			close: async () => {},
		});
	}

	async readBinaryFile(path: string, context: Context): Promise<Result<Uint8Array, FileError>> {
		return this.#run(path, context, (real) => native.fsReadFile(real));
	}

	async openBinaryReader(path: string, options: { noFollow?: boolean } | undefined, context: Context): Promise<Result<BinaryReader, FileError>> {
		const opened = this.#run(path, context, (real) => {
			const info = this.#info(path, real, options?.noFollow !== true);
			if (info.kind === "directory") throw Object.assign(new Error("Is a directory"), { code: "is_directory" });
			return real;
		});
		if (!opened.ok) return opened;
		const real = opened.value;
		const absolute = normalize(path, this.cwd);
		let closed = false;
		const closedError = () => err<never, FileError>(new FileError("invalid", "Binary reader is closed", absolute));
		return ok({
			info: async (context: Context) => (closed ? closedError() : this.#run(path, context, (target) => this.#info(path, target))),
			read: async (offset: number, length: number, context: Context) =>
				closed ? closedError() : this.#run(path, context, () => native.fsReadRange(real, offset, length)),
			scanLines: async (options: { startLine: number; endLine?: number }, context: Context): Promise<Result<LineScan, FileError>> => {
				if (closed) return closedError();
				let scanner: LineScanner;
				try {
					scanner = new LineScanner(options.startLine, options.endLine);
				} catch {
					return err(new FileError("invalid", "Invalid line range", absolute));
				}
				for (let position = 0; ; ) {
					const chunk = this.#run(path, context, () => native.fsReadRange(real, position, 64 * 1024));
					if (!chunk.ok) return chunk;
					if (chunk.value.byteLength === 0) return ok(scanner.finish());
					scanner.push(chunk.value);
					position += chunk.value.byteLength;
				}
			},
			close: async () => {
				closed = true;
			},
		});
	}

	async writeFile(path: string, content: string | Uint8Array, context: Context): Promise<Result<void, FileError>> {
		return this.#run(path, context, (real) => native.fsWrite(real, content, false));
	}

	async appendFile(path: string, content: string | Uint8Array, context: Context): Promise<Result<void, FileError>> {
		return this.#run(path, context, (real) => native.fsWrite(real, content, true));
	}

	async truncateFile(path: string, size: number, context: Context): Promise<Result<void, FileError>> {
		return this.#run(path, context, (real) => native.fsTruncate(real, size));
	}

	async flushFile(path: string, context: Context): Promise<Result<void, FileError>> {
		return this.#run(path, context, (real) => native.fsSync(real));
	}

	async renameFile(sourcePath: string, destinationPath: string, context: Context): Promise<Result<void, FileError>> {
		return this.#run(sourcePath, context, (real) => native.fsRename(real, this.#real(destinationPath)));
	}

	async fileInfo(path: string, context: Context): Promise<Result<FileInfo, FileError>> {
		return this.#run(path, context, (real) => this.#info(path, real, false));
	}

	async listDir(path: string, context: Context): Promise<Result<FileInfo[], FileError>> {
		const directory = normalize(path, this.cwd);
		return this.#run(path, context, (real) =>
			(JSON.parse(native.fsList(real)) as NativeInfo[]).map((entry) => ({
				name: entry.name,
				path: normalize(entry.name, directory),
				kind: entry.kind,
				size: entry.size,
				mtimeMs: entry.mtimeMs,
			})),
		);
	}

	async openDirReader(path: string, context: Context): Promise<Result<DirReader, FileError>> {
		const listed = await this.listDir(path, context);
		if (!listed.ok) return listed;
		let offset = 0;
		return ok({
			next: async (maxEntries: number) => {
				const entries = listed.value.slice(offset, offset + maxEntries);
				offset += entries.length;
				return ok({ entries, done: offset >= listed.value.length });
			},
			close: async () => {},
		});
	}

	async watch(): Promise<Result<FileWatcher, FileError>> {
		return err(new FileError("not_supported", "Watching files is not supported in the sandbox"));
	}

	async canonicalPath(path: string, context: Context): Promise<Result<string, FileError>> {
		return this.#run(path, context, (real) => {
			const resolved = this.#virtual(native.fsRealpath(real));
			if (resolved === undefined) throw Object.assign(new Error("Path resolves outside the sandbox"), { code: "permission_denied" });
			return resolved;
		});
	}

	async exists(path: string, context: Context): Promise<Result<boolean, FileError>> {
		return this.#run(path, context, (real) => {
			try {
				native.fsStat(real, false);
				return true;
			} catch (error) {
				if ((error as { code?: string }).code === "not_found") return false;
				throw error;
			}
		});
	}

	async createDir(path: string, options: { recursive?: boolean } | undefined, context: Context): Promise<Result<void, FileError>> {
		return this.#run(path, context, (real) => native.fsMkdir(real, options?.recursive === true));
	}

	async remove(path: string, options: { recursive?: boolean; force?: boolean } | undefined, context: Context): Promise<Result<void, FileError>> {
		if (normalize(path, this.cwd) === "/") return err(new FileError("permission_denied", "Cannot remove the sandbox root", "/"));
		return this.#run(path, context, (real) => native.fsRemove(real, options?.recursive === true, options?.force === true));
	}

	async createTempDir(prefix: string | undefined, context: Context): Promise<Result<string, FileError>> {
		const path = `/.tmp/${prefix ?? "tmp"}${Date.now().toString(36)}${(this.#temp++).toString(36)}`;
		const created = await this.createDir(path, { recursive: true }, context);
		return created.ok ? ok(path) : created;
	}

	async createTempFile(options: { prefix?: string; suffix?: string } | undefined, context: Context): Promise<Result<string, FileError>> {
		const directory = await this.createDir("/.tmp", { recursive: true }, context);
		if (!directory.ok) return directory;
		const path = `/.tmp/${options?.prefix ?? "tmp"}${Date.now().toString(36)}${(this.#temp++).toString(36)}${options?.suffix ?? ""}`;
		const written = await this.writeFile(path, encoder.encode(""), context);
		return written.ok ? ok(path) : written;
	}

	async exec(): Promise<Result<ShellExecResult, ExecutionError>> {
		return err(new ExecutionError("shell_unavailable", "There is no shell in this environment"));
	}

	async cleanup(): Promise<void> {}
}
