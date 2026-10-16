import Foundation
import os

/// An advisory lock on a storage, held while a ``Harness`` has it open.
///
/// pi-durable has no locking of its own: two harnesses on one storage would both resume its unfinished runs and run
/// the same tool calls twice. The lock lives in a sibling file, `<storage path>.lock`, and `flock` releases it when
/// the process dies, so a crash never leaves a stale lock.
final class StorageLock: Sendable {
    /// The open lock file, or `nil` once released.
    private let descriptor: OSAllocatedUnfairLock<Int32?>

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
        self.descriptor = OSAllocatedUnfairLock(initialState: descriptor)
    }

    deinit { release() }

    /// Releases the lock by closing its descriptor. Safe to call more than once, and from any thread.
    func release() {
        guard let descriptor = descriptor.withLock({ state in defer { state = nil }; return state }) else { return }
        Darwin.close(descriptor)
    }
}
