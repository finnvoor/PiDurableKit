import Foundation

/// A pi-durable identifier. pi-durable allocates IDs from one numeric namespace per storage.
public struct DurableID<Kind>: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(_ rawValue: Int) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "\(rawValue)" }
}

extension DurableID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { rawValue = value }
}

public enum ConversationKind {}
public enum EntryKindTag {}
public enum SubmissionKind {}
public enum TaskKind {}

public typealias ConversationID = DurableID<ConversationKind>

extension DurableID where Kind == ConversationKind {
    /// The root conversation's reserved ID (pi-durable `ROOT_CONVERSATION_ID`).
    public static let root = ConversationID(1)
}
public typealias EntryID = DurableID<EntryKindTag>
public typealias SubmissionID = DurableID<SubmissionKind>
public typealias TaskID = DurableID<TaskKind>

/// A model provider, such as `anthropic` or `openai`.
public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let anthropic: ProviderID = "anthropic"
    public static let openAI: ProviderID = "openai"
    public static let google: ProviderID = "google"
    public static let openRouter: ProviderID = "openrouter"
    public static let mistral: ProviderID = "mistral"
    public static let groq: ProviderID = "groq"
    public static let xAI: ProviderID = "xai"
    public static let deepSeek: ProviderID = "deepseek"
    public static let cerebras: ProviderID = "cerebras"
    public static let fireworks: ProviderID = "fireworks"
    public static let together: ProviderID = "together"
    public static let vercelAIGateway: ProviderID = "vercel-ai-gateway"
}
