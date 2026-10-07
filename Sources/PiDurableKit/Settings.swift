import Foundation

/// Run policy shared by every conversation of a ``Harness``. Never stored; update it any time with
/// ``Harness/updateSettings(_:)``. Unset fields use pi-durable's defaults.
public struct Settings: Encodable, Sendable, Hashable {
    /// pi-ai request options.
    public struct Stream: Encodable, Sendable, Hashable {
        /// Per-request timeout.
        public var timeout: Duration?
        /// Provider SDK retries inside one request attempt.
        public var maxRetries: Int?
        public var maxRetryDelay: Duration?
        /// Extra HTTP headers sent with every model request.
        public var headers: [String: String]?
        /// Provider prompt cache retention: `none`, `short`, or `long`.
        public var cacheRetention: String?
        /// `sse`, `websocket`, or `auto`, for providers that support more than one.
        public var transport: String?
        /// Provider request metadata.
        public var metadata: JSONObject?
        /// Ask for a deferred (batched, polled) response where supported; pi-durable polls it durably.
        public var deferred: Deferred?

        public enum Deferred: Sendable, Hashable {
            case enabled
            /// Enabled, with a completion window: `15m`, `1h`, or `24h`.
            case window(String)
        }

        public init(
            timeout: Duration? = nil, maxRetries: Int? = nil, maxRetryDelay: Duration? = nil,
            headers: [String: String]? = nil, cacheRetention: String? = nil, transport: String? = nil,
            metadata: JSONObject? = nil, deferred: Deferred? = nil
        ) {
            self.transport = transport
            self.metadata = metadata
            self.deferred = deferred
            self.timeout = timeout
            self.maxRetries = maxRetries
            self.maxRetryDelay = maxRetryDelay
            self.headers = headers
            self.cacheRetention = cacheRetention
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyKey.self)
            try container.encodeIfPresent(timeout?.milliseconds, forKey: AnyKey("timeoutMs"))
            try container.encodeIfPresent(maxRetries, forKey: AnyKey("maxRetries"))
            try container.encodeIfPresent(maxRetryDelay?.milliseconds, forKey: AnyKey("maxRetryDelayMs"))
            try container.encodeIfPresent(headers, forKey: AnyKey("headers"))
            try container.encodeIfPresent(cacheRetention, forKey: AnyKey("cacheRetention"))
            try container.encodeIfPresent(transport, forKey: AnyKey("transport"))
            try container.encodeIfPresent(metadata, forKey: AnyKey("metadata"))
            switch deferred {
            case .enabled: try container.encode(true, forKey: AnyKey("deferred"))
            case .window(let window): try container.encode(["window": window], forKey: AnyKey("deferred"))
            case nil: break
            }
        }
    }

    /// Durable retries of failed generation attempts.
    public struct Retry: Encodable, Sendable, Hashable {
        public var enabled: Bool?
        public var maxRetries: Int?
        public var baseDelay: Duration?
        public var maxDelay: Duration?

        public init(enabled: Bool? = nil, maxRetries: Int? = nil, baseDelay: Duration? = nil, maxDelay: Duration? = nil) {
            self.enabled = enabled
            self.maxRetries = maxRetries
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyKey.self)
            try container.encodeIfPresent(enabled, forKey: AnyKey("enabled"))
            try container.encodeIfPresent(maxRetries, forKey: AnyKey("maxRetries"))
            try container.encodeIfPresent(baseDelay?.milliseconds, forKey: AnyKey("baseDelayMs"))
            try container.encodeIfPresent(maxDelay?.milliseconds, forKey: AnyKey("maxAgentDelayMs"))
        }
    }

    /// Automatic compaction thresholds.
    public struct Compaction: Codable, Sendable, Hashable {
        public var enabled: Bool?
        /// Room kept free for the answer.
        public var reserveTokens: Int?
        /// Roughly how much recent context stays verbatim.
        public var keepRecentTokens: Int?
        /// How far below the blocking threshold a background compaction starts; `0` disables it.
        public var backgroundTokens: Int?

        public init(enabled: Bool? = nil, reserveTokens: Int? = nil, keepRecentTokens: Int? = nil, backgroundTokens: Int? = nil) {
            self.enabled = enabled
            self.reserveTokens = reserveTokens
            self.keepRecentTokens = keepRecentTokens
            self.backgroundTokens = backgroundTokens
        }
    }

    /// How often running progress (partial answers, tool output) is committed.
    public struct Progress: Encodable, Sendable, Hashable {
        public var partialInterval: Duration?
        public var outputInterval: Duration?

        public init(partialInterval: Duration? = nil, outputInterval: Duration? = nil) {
            self.partialInterval = partialInterval
            self.outputInterval = outputInterval
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyKey.self)
            try container.encodeIfPresent(partialInterval?.milliseconds, forKey: AnyKey("partialIntervalMs"))
            try container.encodeIfPresent(outputInterval?.milliseconds, forKey: AnyKey("outputIntervalMs"))
        }
    }

    public enum ToolExecution: String, Encodable, Sendable {
        case parallel, sequential
    }

    public enum QueueMode: String, Encodable, Sendable {
        case all
        case oneAtATime = "one-at-a-time"
    }

    /// The default extension selection, by name; `nil` selects every installed extension in install order.
    public var extensions: [String]?
    public var stream: Stream?
    public var retry: Retry?
    public var compaction: Compaction?
    public var progress: Progress?
    public var toolExecution: ToolExecution?
    public var steeringMode: QueueMode?
    public var followUpMode: QueueMode?
    /// How long an idle conversation keeps its last context read in memory; zero drops it once idle. Default ten minutes.
    public var contextRetention: Duration?

    public init(
        extensions: [String]? = nil,
        stream: Stream? = nil,
        retry: Retry? = nil,
        compaction: Compaction? = nil,
        progress: Progress? = nil,
        toolExecution: ToolExecution? = nil,
        steeringMode: QueueMode? = nil,
        followUpMode: QueueMode? = nil,
        contextRetention: Duration? = nil
    ) {
        self.contextRetention = contextRetention
        self.extensions = extensions
        self.stream = stream
        self.retry = retry
        self.compaction = compaction
        self.progress = progress
        self.toolExecution = toolExecution
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encodeIfPresent(extensions, forKey: AnyKey("extensions"))
        try container.encodeIfPresent(stream, forKey: AnyKey("stream"))
        try container.encodeIfPresent(retry, forKey: AnyKey("retry"))
        try container.encodeIfPresent(compaction, forKey: AnyKey("compaction"))
        try container.encodeIfPresent(progress, forKey: AnyKey("progress"))
        try container.encodeIfPresent(toolExecution, forKey: AnyKey("toolExecution"))
        try container.encodeIfPresent(steeringMode, forKey: AnyKey("steeringMode"))
        try container.encodeIfPresent(followUpMode, forKey: AnyKey("followUpMode"))
        try container.encodeIfPresent(contextRetention?.milliseconds, forKey: AnyKey("contextRetentionMs"))
    }
}

extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
