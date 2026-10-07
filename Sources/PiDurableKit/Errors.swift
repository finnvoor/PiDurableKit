import Foundation

/// An error raised by pi-durable or by the PiDurableKit bridge.
public enum PiDurableError: Error, Sendable, LocalizedError, CustomStringConvertible {
    /// A submission with `whenBusy: .reject` reached a busy conversation.
    case conversationBusy(String)
    /// A transaction read a table (conversations, entries, tasks) after its first table write. Read first, then write.
    case readAfterWrite(String)
    /// Storage rejected a commit before any durable effect; the harness can continue.
    case storageRejected(String)
    /// The conversation, submission, or entry does not exist.
    case notFound(String)
    /// A wait or operation was cancelled.
    case cancelled
    /// Any other JavaScript error thrown by pi-durable or pi-ai.
    case javaScript(name: String, message: String, stack: String?)
    /// The JavaScript runtime could not be started.
    case runtime(String)
    /// A value returned by pi-durable did not have the expected shape.
    case decoding(method: String, underlying: any Error, json: String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .conversationBusy(let message): "Conversation busy: \(message)"
        case .readAfterWrite(let message): message
        case .storageRejected(let message): "Storage rejected the commit: \(message)"
        case .notFound(let message): message
        case .cancelled: "Cancelled"
        case .javaScript(let name, let message, _): "\(name): \(message)"
        case .runtime(let message): message
        case .decoding(let method, let underlying, let json):
            "Could not decode the result of \(method): \(underlying)\n\(json.prefix(2000))"
        }
    }

    init(javaScriptJSON json: String) {
        struct Info: Decodable {
            var name: String?
            var message: String?
            var stack: String?
        }
        let info = (try? JSONDecoder().decode(Info.self, from: Data(json.utf8))) ?? Info(message: json)
        let name = info.name ?? "Error"
        let message = info.message ?? ""
        switch name {
        case "ConversationBusy": self = .conversationBusy(message)
        case "ReadAfterWrite": self = .readAfterWrite(message)
        case "StorageRejected": self = .storageRejected(message)
        case "NotFound": self = .notFound(message)
        case "AbortError" where message.localizedCaseInsensitiveContains("abort"): self = .cancelled
        default: self = .javaScript(name: name, message: message, stack: info.stack)
        }
    }
}
