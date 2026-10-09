import Foundation

/// An advisory lock on a storage, held while a ``Harness`` has it open.
///
/// pi-durable has no locking of its own: two harnesses on one storage would both resume its unfinished runs and run
/// the same tool calls twice. The lock lives in a sibling file, `<storage path>.lock`, and `flock` releases it when
/// the process dies, so a crash never leaves a stale lock.
final class StorageLock: Sendable {
    private let descriptor: Int32

    /// Locks the storage at `path`, or throws when another harness (in this process or another) holds it.
    init(storagePath path: String) throws {
        let lockPath = path + ".lock"
        let descriptor = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw FileOperationError.posix(lockPath) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            Darwin.close(descriptor)
            if busy {
                throw PiDurableError.runtime("The storage at \(path) is already open in another harness. Close it first.")
            }
            throw FileOperationError.posix(lockPath)
        }
        self.descriptor = descriptor
    }

    deinit { release() }

    /// Releases the lock. Closing the descriptor drops it.
    func release() {
        Darwin.close(descriptor)
    }
}
