import Foundation

/// Something handed to a conversation, user input or an entry write, that you can wait for (pi-durable `Submission`).
///
/// Submissions are durable: after a restart, reacquire one with ``Harness/submission(_:)`` and wait again.
/// Cancelling a wait only cancels that wait, never the work.
public struct Submission: Sendable, Identifiable, Hashable {
    public let harness: Harness
    public let id: SubmissionID

    init(harness: Harness, id: SubmissionID) {
        self.harness = harness
        self.id = id
    }

    public static func == (lhs: Submission, rhs: Submission) -> Bool {
        lhs.id == rhs.id && lhs.harness === rhs.harness
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(ObjectIdentifier(harness))
    }

    /// The submission's current record.
    public func status() async throws -> SubmissionRecord {
        guard let record: SubmissionRecord? = try await harness.call("submission.status", ["submission": id]),
            let record
        else {
            throw PiDurableError.notFound("Submission \(id) does not exist")
        }
        return record
    }

    /// Waits until the input is answered or can no longer be answered.
    @discardableResult
    public func wait() async throws -> SubmissionRecord {
        try await harness.call("submission.wait", ["submission": id])
    }

    /// The outcome of ``abort()``.
    public enum AbortResult: String, Decodable, Sendable {
        /// Withdrawn from the inbox before it was placed.
        case aborted
        /// Already in the transcript; abort the conversation to stop its run.
        case alreadyPlaced = "already_placed"
        /// Already answered or unanswered.
        case settled
        case notFound = "not_found"
    }

    /// Withdraws a queued submission.
    @discardableResult
    public func abort() async throws -> AbortResult {
        try await harness.call("submission.abort", ["submission": id])
    }
}

