import Foundation
import os

/// An in-memory model provider with scripted responses (pi-ai `fauxProvider`), for tests, SwiftUI previews, and
/// demos. Responses stream like a real provider's.
///
/// ```swift
/// let faux = FauxProvider()
/// try await models.register(faux)
/// try await faux.append(.text("Hello!"), .toolCall("get_weather", ["city": "Paris"]))
/// let conversation = try await harness.root(agent: AgentChange(model: faux.model))
/// ```
///
/// Responses are consumed in request order. With an empty queue, requests fail with
/// "No more faux responses queued" unless a ``respond(_:)`` responder is set.
public final class FauxProvider: Sendable {
    public struct Model: Encodable, Sendable {
        public var id: String
        public var name: String?
        public var reasoning: Bool
        public var contextWindow: Int?

        public init(id: String, name: String? = nil, reasoning: Bool = false, contextWindow: Int? = nil) {
            self.id = id
            self.name = name
            self.reasoning = reasoning
            self.contextWindow = contextWindow
        }
    }

    public let id: ProviderID
    let models: [Model]
    let tokensPerSecond: Double?
    private let registration = OSAllocatedUnfairLock<Models?>(initialState: nil)

    /// - Parameters:
    ///   - id: The provider ID; use distinct IDs for independent scripted flows.
    ///   - models: The provider's models. Defaults to one model, `faux-1`.
    ///   - tokensPerSecond: Paces streaming in real time; by default chunks stream as fast as possible.
    public init(id: ProviderID = "faux", models: [Model] = [Model(id: "faux-1")], tokensPerSecond: Double? = nil) {
        self.id = id
        self.models = models
        self.tokensPerSecond = tokensPerSecond
    }

    /// The first model, for ``AgentChange/model``.
    public var model: ModelRef { ModelRef(provider: id, modelId: models.first?.id ?? "faux-1") }

    /// A model by ID.
    public func model(_ modelId: String) -> ModelRef { ModelRef(provider: id, modelId: modelId) }

    func attach(to models: Models) {
        registration.withLock { $0 = models }
    }

    private func registered() throws -> Models {
        guard let models = registration.withLock({ $0 }) else {
            throw PiDurableError.runtime("Register the faux provider with Models.register(_:) first")
        }
        return models
    }

    /// Appends one scripted response made of these blocks.
    public func append(_ blocks: FauxResponse.Block..., stopReason: StopReason? = nil) async throws {
        try await append([FauxResponse(blocks, stopReason: stopReason)])
    }

    /// Appends scripted responses.
    public func append(_ responses: [FauxResponse]) async throws {
        try await registered().perform("faux.append", ["provider": id, "responses": responses])
    }

    /// Replaces the queue of scripted responses.
    public func setResponses(_ responses: [FauxResponse]) async throws {
        try await registered().perform("faux.set", ["provider": id, "responses": responses])
    }

    /// Answers every request with `responder`, which receives the request's messages and the request count.
    public func respond(_ responder: @escaping @Sendable (_ messages: [Message], _ callCount: Int) async throws -> FauxResponse)
        async throws
    {
        let models = try registered()
        models.runtime.engine.host.setResponder(models: models.id, provider: id, responder)
        try await models.perform("faux.respond", ["provider": id])
    }

    /// How many scripted responses are still queued.
    public func pendingResponseCount() async throws -> Int {
        try await registered().call("faux.pending", ["provider": id])
    }
}

/// One scripted model response.
public struct FauxResponse: Encodable, Sendable {
    public enum Block: Encodable, Sendable {
        case text(String)
        case thinking(String)
        case toolCall(String, JSONObject, id: String? = nil)

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyKey.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: AnyKey("type"))
                try container.encode(text, forKey: AnyKey("text"))
            case .thinking(let thinking):
                try container.encode("thinking", forKey: AnyKey("type"))
                try container.encode(thinking, forKey: AnyKey("thinking"))
            case .toolCall(let name, let arguments, let id):
                try container.encode("toolCall", forKey: AnyKey("type"))
                try container.encode(id ?? "call_\(UUID().uuidString.prefix(8).lowercased())", forKey: AnyKey("id"))
                try container.encode(name, forKey: AnyKey("name"))
                try container.encode(arguments, forKey: AnyKey("arguments"))
            }
        }
    }

    public var blocks: [Block]
    /// Defaults to `toolUse` when a block is a tool call, else `stop`.
    public var stopReason: StopReason?
    public var errorMessage: String?

    public init(_ blocks: [Block], stopReason: StopReason? = nil, errorMessage: String? = nil) {
        self.blocks = blocks
        self.stopReason = stopReason
        self.errorMessage = errorMessage
    }

    public init(_ blocks: Block..., stopReason: StopReason? = nil) {
        self.init(blocks, stopReason: stopReason)
    }

    /// A plain text answer.
    public static func text(_ text: String) -> FauxResponse { FauxResponse([.text(text)]) }

    /// A failed request.
    public static func error(_ message: String) -> FauxResponse {
        FauxResponse([], stopReason: .error, errorMessage: message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(blocks, forKey: AnyKey("content"))
        let hasToolCall = blocks.contains { if case .toolCall = $0 { true } else { false } }
        try container.encode(stopReason ?? (hasToolCall ? .toolUse : .stop), forKey: AnyKey("stopReason"))
        try container.encodeIfPresent(errorMessage, forKey: AnyKey("errorMessage"))
    }
}
