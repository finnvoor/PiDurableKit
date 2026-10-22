import Foundation

/// Run policy shared by every conversation of a ``Harness``. Never stored; update it any time with
/// ``Harness/updateSettings(_:)``. Unset fields use pi-durable's defaults.
public struct Settings: Codable, Sendable, Hashable {
    /// pi-ai request options.
    public struct Stream: Codable, Sendable, Hashable {
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            timeout = try container.decodeIfPresent(Double.self, forKey: AnyKey("timeoutMs")).map { Duration.milliseconds($0) }
            maxRetries = try container.decodeIfPresent(Int.self, forKey: AnyKey("maxRetries"))
            maxRetryDelay = try container.decodeIfPresent(Double.self, forKey: AnyKey("maxRetryDelayMs")).map { Duration.milliseconds($0) }
            headers = try container.decodeIfPresent([String: String].self, forKey: AnyKey("headers"))
            cacheRetention = try container.decodeIfPresent(String.self, forKey: AnyKey("cacheRetention"))
            transport = try container.decodeIfPresent(String.self, forKey: AnyKey("transport"))
            metadata = try container.decodeIfPresent(JSONObject.self, forKey: AnyKey("metadata"))
            let deferred = try container.decodeIfPresent(JSONValue.self, forKey: AnyKey("deferred"))
            if let window = deferred?["window"]?.stringValue {
                self.deferred = .window(window)
            } else if deferred?.boolValue == true || deferred?.objectValue != nil {
                self.deferred = .enabled
            } else {
                self.deferred = nil
            }
        }
    }

    /// Durable retries of failed generation attempts.
    public struct Retry: Codable, Sendable, Hashable {
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: AnyKey("enabled"))
            maxRetries = try container.decodeIfPresent(Int.self, forKey: AnyKey("maxRetries"))
            baseDelay = try container.decodeIfPresent(Double.self, forKey: AnyKey("baseDelayMs")).map { Duration.milliseconds($0) }
            maxDelay = try container.decodeIfPresent(Double.self, forKey: AnyKey("maxAgentDelayMs")).map { Duration.milliseconds($0) }
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
        /// Thresholds for particular models, so small- and large-window models can share a harness: each field an
        /// override sets replaces the harness-wide one for that model (its own `modelOverrides` are ignored).
        public var modelOverrides: [ModelRef: Compaction]?

        public init(
            enabled: Bool? = nil, reserveTokens: Int? = nil, keepRecentTokens: Int? = nil, backgroundTokens: Int? = nil,
            modelOverrides: [ModelRef: Compaction]? = nil
        ) {
            self.enabled = enabled
            self.reserveTokens = reserveTokens
            self.keepRecentTokens = keepRecentTokens
            self.backgroundTokens = backgroundTokens
            self.modelOverrides = modelOverrides
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyKey.self)
            try container.encodeIfPresent(enabled, forKey: AnyKey("enabled"))
            try container.encodeIfPresent(reserveTokens, forKey: AnyKey("reserveTokens"))
            try container.encodeIfPresent(keepRecentTokens, forKey: AnyKey("keepRecentTokens"))
            try container.encodeIfPresent(backgroundTokens, forKey: AnyKey("backgroundTokens"))
            if let modelOverrides {
                // Keyed by exact `provider/modelId`, as pi-durable matches them.
                let keyed = Dictionary(modelOverrides.map { (model, policy) in
                    var policy = policy
                    policy.modelOverrides = nil
                    return (model.description, policy)
                }, uniquingKeysWith: { _, last in last })
                try container.encode(keyed, forKey: AnyKey("modelOverrides"))
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: AnyKey("enabled"))
            reserveTokens = try container.decodeIfPresent(Int.self, forKey: AnyKey("reserveTokens"))
            keepRecentTokens = try container.decodeIfPresent(Int.self, forKey: AnyKey("keepRecentTokens"))
            backgroundTokens = try container.decodeIfPresent(Int.self, forKey: AnyKey("backgroundTokens"))
            let keyed = try container.decodeIfPresent([String: Compaction].self, forKey: AnyKey("modelOverrides"))
            modelOverrides = keyed.map { keyed in
                Dictionary(keyed.compactMap { key, policy -> (ModelRef, Compaction)? in
                    guard let slash = key.firstIndex(of: "/") else { return nil }
                    let model = ModelRef(provider: ProviderID(String(key[..<slash])), modelId: String(key[key.index(after: slash)...]))
                    return (model, policy)
                }, uniquingKeysWith: { _, last in last })
            }
        }

        /// Thresholds in proportion to a small context window, such as the on-device model's: pi-durable's defaults
        /// (16,384 tokens reserved, 20,000 kept) suit large windows and would never compact a window of a few thousand
        /// tokens before it overflows. Half the window stays free, so the request that summarizes older entries fits
        /// the same window, and a quarter is kept verbatim.
        public static func forContextWindow(_ tokens: Int) -> Compaction {
            Compaction(reserveTokens: tokens / 2, keepRecentTokens: tokens / 4, backgroundTokens: tokens / 8)
        }
    }

    /// How often running progress (partial answers, tool output) is committed.
    public struct Progress: Codable, Sendable, Hashable {
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            partialInterval = try container.decodeIfPresent(Double.self, forKey: AnyKey("partialIntervalMs")).map { Duration.milliseconds($0) }
            outputInterval = try container.decodeIfPresent(Double.self, forKey: AnyKey("outputIntervalMs")).map { Duration.milliseconds($0) }
        }
    }

    public enum ToolExecution: String, Codable, Sendable {
        case parallel, sequential
    }

    public enum QueueMode: String, Codable, Sendable {
        case all
        case oneAtATime = "one-at-a-time"
    }

    /// What a run that fails with a model error, or without a model, does with the inputs queued behind it
    /// (pi-durable `AfterFailedRun`).
    public enum AfterFailedRun: String, Codable, Sendable {
        /// Leave them queued until the next input or queued write (the default).
        case keep
        /// Start the next run with them, as an answer would.
        case `continue`
        /// Settle them `unanswered`, with reason `run_failed`.
        case withdraw
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
    /// How long a loaded document that nothing observes stays in memory after its last read or write; the next access
    /// loads it from storage. Zero drops it right after use, `Duration.forever` keeps documents. Default ten minutes.
    public var documentRetention: Duration?
    /// What a run that fails with a model error does with the inputs queued behind it. Default ``AfterFailedRun/keep``.
    public var afterFailedRun: AfterFailedRun?
    /// How many times in a row a crash, eviction, or reset may cut a task off without it changing its state before it is
    /// parked (blocked with ``BlockedReason/restartLimit``) instead of run again; ``Harness/retryTask(_:)`` runs it
    /// again. A close doesn't count. Default 5; `Int.max` never parks.
    public var restartLimit: Int?

    public init(
        extensions: [String]? = nil,
        stream: Stream? = nil,
        retry: Retry? = nil,
        compaction: Compaction? = nil,
        progress: Progress? = nil,
        toolExecution: ToolExecution? = nil,
        steeringMode: QueueMode? = nil,
        followUpMode: QueueMode? = nil,
        contextRetention: Duration? = nil,
        documentRetention: Duration? = nil,
        afterFailedRun: AfterFailedRun? = nil,
        restartLimit: Int? = nil
    ) {
        self.contextRetention = contextRetention
        self.documentRetention = documentRetention
        self.afterFailedRun = afterFailedRun
        self.restartLimit = restartLimit
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
        try container.encodeIfPresent(documentRetention?.milliseconds, forKey: AnyKey("documentRetentionMs"))
        try container.encodeIfPresent(afterFailedRun, forKey: AnyKey("afterFailedRun"))
        try container.encodeIfPresent(restartLimit, forKey: AnyKey("restartLimit"))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        extensions = try container.decodeIfPresent([String].self, forKey: AnyKey("extensions"))
        stream = try container.decodeIfPresent(Stream.self, forKey: AnyKey("stream"))
        retry = try container.decodeIfPresent(Retry.self, forKey: AnyKey("retry"))
        compaction = try container.decodeIfPresent(Compaction.self, forKey: AnyKey("compaction"))
        progress = try container.decodeIfPresent(Progress.self, forKey: AnyKey("progress"))
        toolExecution = try container.decodeIfPresent(ToolExecution.self, forKey: AnyKey("toolExecution"))
        steeringMode = try container.decodeIfPresent(QueueMode.self, forKey: AnyKey("steeringMode"))
        followUpMode = try container.decodeIfPresent(QueueMode.self, forKey: AnyKey("followUpMode"))
        contextRetention = try container.decodeIfPresent(Double.self, forKey: AnyKey("contextRetentionMs")).map { Duration.milliseconds($0) }
        // An infinite retention arrives as `null`.
        if container.contains(AnyKey("documentRetentionMs")) {
            documentRetention = try container.decodeIfPresent(Double.self, forKey: AnyKey("documentRetentionMs")).map { Duration.milliseconds($0) } ?? .forever
        } else {
            documentRetention = nil
        }
        afterFailedRun = try container.decodeIfPresent(AfterFailedRun.self, forKey: AnyKey("afterFailedRun"))
        // An unlimited restart limit arrives as `null`.
        if container.contains(AnyKey("restartLimit")) {
            restartLimit = try container.decodeIfPresent(Double.self, forKey: AnyKey("restartLimit")).map { $0 >= 9e15 ? Int.max : Int($0) } ?? .max
        } else {
            restartLimit = nil
        }
    }
}

extension Duration {
    /// A retention that never ends, for ``Settings/documentRetention``.
    public static var forever: Duration { .seconds(Int64.max / 2) }

    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
