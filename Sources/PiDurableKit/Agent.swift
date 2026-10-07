import Foundation

/// A model, by provider and ID, resolved through ``Models``.
public struct ModelRef: Codable, Hashable, Sendable, CustomStringConvertible {
    public var provider: ProviderID
    public var modelId: String

    public init(provider: ProviderID, modelId: String) {
        self.provider = provider
        self.modelId = modelId
    }

    public var description: String { "\(provider)/\(modelId)" }

    public static func anthropic(_ modelId: String) -> ModelRef { ModelRef(provider: .anthropic, modelId: modelId) }
    public static func openAI(_ modelId: String) -> ModelRef { ModelRef(provider: .openAI, modelId: modelId) }
    public static func google(_ modelId: String) -> ModelRef { ModelRef(provider: .google, modelId: modelId) }
    public static func openRouter(_ modelId: String) -> ModelRef { ModelRef(provider: .openRouter, modelId: modelId) }
}

/// How much a reasoning model thinks before answering.
public enum ThinkingLevel: String, Codable, Sendable, CaseIterable {
    case off, minimal, low, medium, high, xhigh, max
}

/// A conversation's stored agent choices (`pi.agent`). Unset fields follow the harness defaults.
public struct AgentState: Codable, Sendable, Hashable {
    public var model: ModelRef?
    public var thinkingLevel: ThinkingLevel?
    /// The raw extension selection: an array of names, or an `{ add, remove }` edit of the default.
    public var extensions: JSONValue?
    /// The raw tool filter: an array of names, or `{ remove }`.
    public var tools: JSONValue?
    public var instructions: String?
    public var cwd: String?

    public init() {}
}

/// A conversation's agent, resolved against the installed extensions and the settings.
public struct Agent: Codable, Sendable, Hashable {
    public var model: ModelRef?
    public var thinkingLevel: ThinkingLevel
    /// Selected extensions, in order.
    public var extensions: [String]
    /// The tools a request offers, in order.
    public var tools: [String]
    public var instructions: String?
    public var cwd: String?
}

/// A change to a conversation's agent (`configure()`).
///
/// Fields left `nil` keep their stored value; fields listed in `reset` return to the harness default.
///
/// ```swift
/// try await conversation.configure(AgentChange(model: .anthropic("claude-sonnet-4-5"), thinkingLevel: .high))
/// try await conversation.configure(AgentChange(reset: [.tools, .instructions]))
/// ```
public struct AgentChange: Encodable, Sendable, Hashable {
    /// A field of the agent that can be reset to the harness default.
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case model, thinkingLevel, extensions, tools, instructions, cwd
    }

    /// Which extensions a conversation selects.
    public enum Extensions: Sendable, Hashable {
        /// Exactly these extensions, in order.
        case only([String])
        /// The harness default, with some added and some removed.
        case edit(add: [String] = [], remove: [String] = [])

        public static func add(_ extensions: Extension...) -> Extensions { .edit(add: extensions.map(\.name)) }
        public static func remove(_ extensions: Extension...) -> Extensions { .edit(remove: extensions.map(\.name)) }
        public static func only(_ extensions: Extension...) -> Extensions { .only(extensions.map(\.name)) }
    }

    /// Which tools of the selected extensions a conversation offers.
    public enum Tools: Sendable, Hashable {
        /// Exactly these tools, in order.
        case only([String])
        /// Every tool except these.
        case remove([String])

        public static func only(_ tools: Tool...) -> Tools { .only(tools.map(\.name)) }
        public static func remove(_ tools: Tool...) -> Tools { .remove(tools.map(\.name)) }
    }

    public var model: ModelRef?
    public var thinkingLevel: ThinkingLevel?
    public var extensions: Extensions?
    public var tools: Tools?
    /// Rendered last in the system prompt, as the section `instructions`.
    public var instructions: String?
    /// The working directory passed to the execution environment.
    public var cwd: String?
    /// Fields cleared back to the harness default.
    public var reset: Set<Field>

    public init(
        model: ModelRef? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        extensions: Extensions? = nil,
        tools: Tools? = nil,
        instructions: String? = nil,
        cwd: String? = nil,
        reset: Set<Field> = []
    ) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.extensions = extensions
        self.tools = tools
        self.instructions = instructions
        self.cwd = cwd
        self.reset = reset
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for field in reset { try container.encodeNil(forKey: AnyKey(field.rawValue)) }
        try container.encodeIfPresent(model, forKey: AnyKey("model"))
        try container.encodeIfPresent(thinkingLevel, forKey: AnyKey("thinkingLevel"))
        try container.encodeIfPresent(instructions, forKey: AnyKey("instructions"))
        try container.encodeIfPresent(cwd, forKey: AnyKey("cwd"))
        switch extensions {
        case .only(let names): try container.encode(names, forKey: AnyKey("extensions"))
        case .edit(let add, let remove): try container.encode(["add": add, "remove": remove], forKey: AnyKey("extensions"))
        case nil: break
        }
        switch tools {
        case .only(let names): try container.encode(names, forKey: AnyKey("tools"))
        case .remove(let names): try container.encode(["remove": names], forKey: AnyKey("tools"))
        case nil: break
        }
    }
}
