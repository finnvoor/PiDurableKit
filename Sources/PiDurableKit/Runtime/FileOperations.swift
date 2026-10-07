import Foundation

/// A file system failure with a pi-durable `FileErrorCode`.
struct FileOperationError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }

    init(code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    init(_ error: Error, path: String) {
        let nsError = error as NSError
        var code = "unknown"
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: code = "not_found"
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: code = "permission_denied"
            case NSFileWriteFileExistsError: code = "invalid"
            default: break
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                code = FileOperationError.code(posix: Int32(underlying.code)) ?? code
            }
        } else if nsError.domain == NSPOSIXErrorDomain {
            code = FileOperationError.code(posix: Int32(nsError.code)) ?? code
        }
        self.init(code: code, "\(path): \(error.localizedDescription)")
    }

    static func code(posix: Int32) -> String? {
        switch posix {
        case ENOENT: "not_found"
        case EACCES, EPERM: "permission_denied"
        case ENOTDIR: "not_directory"
        case EISDIR: "is_directory"
        case EINVAL, EEXIST, ENOTEMPTY: "invalid"
        default: nil
        }
    }

    static func posix(_ path: String) -> FileOperationError {
        let number = errno
        return FileOperationError(
            code: code(posix: number) ?? "unknown", "\(path): \(String(cString: strerror(number)))")
    }
}

/// Host file operations behind the sandboxed environment (`JS/src/bridge/env.ts`). Paths are real paths that the
/// JavaScript side already confined to the sandbox root.
enum FileOperations {
    private static var manager: FileManager { .default }

    struct Info: Encodable {
        let name: String
        let kind: String
        let size: Double
        let mtimeMs: Double
    }

    static func info(_ path: String, follow: Bool) throws -> Info {
        var status = Darwin.stat()
        let result = follow ? stat(path, &status) : lstat(path, &status)
        guard result == 0 else { throw FileOperationError.posix(path) }
        let kind: String
        switch status.st_mode & S_IFMT {
        case S_IFDIR: kind = "directory"
        case S_IFLNK: kind = "symlink"
        default: kind = "file"
        }
        let modified = Double(status.st_mtimespec.tv_sec) * 1000 + Double(status.st_mtimespec.tv_nsec) / 1_000_000
        return Info(name: (path as NSString).lastPathComponent, kind: kind, size: Double(status.st_size), mtimeMs: modified)
    }

    static func statJSON(_ path: String, follow: Bool) throws -> String {
        try String(decoding: JSONEncoder().encode(info(path, follow: follow)), as: UTF8.self)
    }

    static func read(_ path: String) throws -> Data {
        if try info(path, follow: true).kind == "directory" {
            throw FileOperationError(code: "is_directory", "\(path): is a directory")
        }
        do {
            return try Data(contentsOf: URL(filePath: path))
        } catch {
            throw FileOperationError(error, path: path)
        }
    }

    static func read(_ path: String, offset: Int, length: Int) throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FileOperationError.posix(path) }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: max(0, length)) ?? Data()
        } catch {
            throw FileOperationError(error, path: path)
        }
    }

    /// Writes or appends, creating missing parent directories (like pi-durable's Node environment).
    static func write(_ path: String, _ data: Data, append: Bool) throws {
        let url = URL(filePath: path)
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append, let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            throw FileOperationError(error, path: path)
        }
    }

    static func truncate(_ path: String, size: Int) throws {
        guard Darwin.truncate(path, off_t(size)) == 0 else { throw FileOperationError.posix(path) }
    }

    static func sync(_ path: String) throws {
        let descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor >= 0 else { throw FileOperationError.posix(path) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw FileOperationError.posix(path) }
    }

    static func rename(_ source: String, _ destination: String) throws {
        guard Darwin.rename(source, destination) == 0 else { throw FileOperationError.posix(source) }
    }

    static func list(_ path: String) throws -> String {
        guard try info(path, follow: true).kind == "directory" else {
            throw FileOperationError(code: "not_directory", "\(path): not a directory")
        }
        let names: [String]
        do {
            names = try manager.contentsOfDirectory(atPath: path).sorted()
        } catch {
            throw FileOperationError(error, path: path)
        }
        let entries = names.compactMap { try? info((path as NSString).appendingPathComponent($0), follow: false) }
        return String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
    }

    static func makeDirectory(_ path: String, recursive: Bool) throws {
        do {
            try manager.createDirectory(atPath: path, withIntermediateDirectories: recursive)
        } catch {
            var isDirectory: ObjCBool = false
            if recursive, manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return }
            throw FileOperationError(error, path: path)
        }
    }

    static func remove(_ path: String, recursive: Bool, force: Bool) throws {
        guard let kind = try? info(path, follow: false).kind else {
            if force { return }
            throw FileOperationError(code: "not_found", "\(path): no such file or directory")
        }
        if kind == "directory", !recursive, !((try? manager.contentsOfDirectory(atPath: path))?.isEmpty ?? true) {
            throw FileOperationError(code: "invalid", "\(path): directory not empty")
        }
        do {
            try manager.removeItem(atPath: path)
        } catch {
            throw FileOperationError(error, path: path)
        }
    }

    static func realPath(_ path: String) throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else { throw FileOperationError.posix(path) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
