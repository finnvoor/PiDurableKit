import Foundation
import os

/// A recorder of the content-free spans, events, and metrics a ``Harness`` emits (pi-durable `HarnessOptions.telemetry`):
/// submission admissions, task phases, committed entries, and model requests, by ID, never content. Pass it to
/// ``Harness/open(_:models:extensions:settings:environment:resume:onConversationCreated:clock:timer:onWake:onReport:identity:telemetry:)``,
/// then read back settled traces and metrics.
///
/// ```swift
/// let telemetry = try await Telemetry.sqlite(at: directory.appending(path: "telemetry.sqlite"))
/// let harness = try await Harness.open(.sqlite(at: url), models: models, telemetry: telemetry)
/// // …
/// let slow = try await telemetry.traces(TraceQuery(name: "pi.durable.phase"))
/// ```
///
/// ``schemas(runtime:)`` describes every span, event, attribute, and metric.
public final class Telemetry: Sendable {
    let runtime: Runtime
    let id: Int

    private init(runtime: Runtime, id: Int) {
        self.runtime = runtime
        self.id = id
    }

    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    private static func create(_ arguments: BridgeArguments, runtime: Runtime) async throws -> Telemetry {
        let id = counter.withLock { value in
            value += 1
            return value
        }
        var arguments = arguments
        arguments["telemetry"] = id
        try await runtime.engine.perform("telemetry.create", arguments)
        return Telemetry(runtime: runtime, id: id)
    }

    /// Records in memory (pi-telemetry `InMemoryTelemetryContext`), for tests and short sessions; every span is kept.
    public static func memory(runtime: Runtime = .shared) async throws -> Telemetry {
        try await create(["kind": "memory"], runtime: runtime)
    }

    /// Records into a SQLite database file (chord `createSqliteTelemetry`): settled spans and ten-second metric
    /// aggregates, written every second, older ones removed after `retention`. Recording itself never waits on SQL.
    ///
    /// - Parameters:
    ///   - url: The database file; it may be the harness's own, as the tables don't overlap.
    ///   - retention: How long spans and metrics are kept; default seven days.
    ///   - maxQueuedSpans: Settled spans waiting to be written before new ones are dropped; default 10,000.
    ///   - runtime: The JavaScript runtime to record in; a harness recording here must use the same runtime.
    public static func sqlite(
        at url: URL, retention: Duration? = nil, maxQueuedSpans: Int? = nil, runtime: Runtime = .shared
    ) async throws -> Telemetry {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try await create(
            [
                "kind": "sqlite", "path": url.path(percentEncoded: false), "retentionMs": retention?.milliseconds,
                "maxQueuedSpans": maxQueuedSpans,
            ], runtime: runtime)
    }

    /// Records into a SQLite database you implement, as ``Storage/sqlite(database:tablePrefix:)`` does.
    public static func sqlite(
        database: some SQLiteDatabase, retention: Duration? = nil, maxQueuedSpans: Int? = nil, runtime: Runtime = .shared
    ) async throws -> Telemetry {
        try await create(
            [
                "kind": "database", "database": runtime.engine.host.register(database), "retentionMs": retention?.milliseconds,
                "maxQueuedSpans": maxQueuedSpans,
            ], runtime: runtime)
    }

    private func call<Result: Decodable & Sendable>(_ method: String, _ arguments: BridgeArguments = [:]) async throws -> Result {
        var arguments = arguments
        arguments["telemetry"] = id
        return try await runtime.engine.call(method, arguments)
    }

    /// Settled traces, newest first by their earliest span, one page at a time.
    public func traces(_ query: TraceQuery = TraceQuery()) async throws -> TracePage {
        try await call("telemetry.traces", ["query": query])
    }

    /// One trace's settled spans.
    public func trace(_ id: String) async throws -> StoredTrace? {
        try await call("telemetry.trace", ["trace": id])
    }

    /// Metric measurements: aggregated per ten-second interval in SQLite, one per measurement in memory.
    public func metrics(_ query: MetricQuery) async throws -> [StoredMetric] {
        try await call("telemetry.metrics", ["query": query])
    }

    /// Writes settled spans and completed metric intervals now, instead of at the next second.
    public func flush() async throws {
        try await runtime.engine.perform("telemetry.flush", ["telemetry": id])
    }

    /// Spans and measurements dropped because too many were waiting to be written.
    public func dropped() async throws -> (spans: Int, measurements: Int) {
        struct Dropped: Decodable { let spans: Int; let measurements: Int }
        let dropped: Dropped = try await call("telemetry.dropped")
        return (dropped.spans, dropped.measurements)
    }

    /// Stops recording and writes what is left, including partial metric intervals. Close harnesses recording here first.
    public func close() async throws {
        try await runtime.engine.perform("telemetry.close", ["telemetry": id])
    }

    /// The span, event, attribute, and metric vocabularies pi-durable (`durable`) and pi-ai (`ai`) record.
    public static func schemas(runtime: Runtime = .shared) async throws -> (durable: JSONValue, ai: JSONValue) {
        struct Schemas: Decodable { let durable: JSONValue; let ai: JSONValue }
        let schemas: Schemas = try await runtime.engine.call("telemetry.schemas")
        return (schemas.durable, schemas.ai)
    }

    func spanSpecification(_ name: String) -> JSONValue {
        ["telemetry": .number(Double(id)), "span": .string(name)]
    }
}

/// Which traces ``Telemetry/traces(_:)`` returns (pi-telemetry `TraceQuery`).
public struct TraceQuery: Encodable, Sendable, Hashable {
    /// The name of the trace's earliest span.
    public var name: String?
    /// Attribute values one span of the trace has, all of them.
    public var attributes: [String: JSONValue]?
    /// Only traces with a failed span.
    public var errorsOnly: Bool
    /// Bounds on the earliest span's start.
    public var startedAfter: Date?
    public var startedBefore: Date?
    /// Page size; default 20.
    public var limit: Int?
    /// ``TracePage/cursor`` of the previous page, with the same filters.
    public var cursor: String?

    public init(
        name: String? = nil, attributes: [String: JSONValue]? = nil, errorsOnly: Bool = false, startedAfter: Date? = nil,
        startedBefore: Date? = nil, limit: Int? = nil, cursor: String? = nil
    ) {
        self.name = name
        self.attributes = attributes
        self.errorsOnly = errorsOnly
        self.startedAfter = startedAfter
        self.startedBefore = startedBefore
        self.limit = limit
        self.cursor = cursor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encodeIfPresent(name, forKey: AnyKey("name"))
        try container.encodeIfPresent(attributes, forKey: AnyKey("attributes"))
        if errorsOnly { try container.encode(true, forKey: AnyKey("errors")) }
        try container.encodeIfPresent(startedAfter.map { $0.timeIntervalSince1970 * 1000 }, forKey: AnyKey("startMin"))
        try container.encodeIfPresent(startedBefore.map { $0.timeIntervalSince1970 * 1000 }, forKey: AnyKey("startMax"))
        try container.encodeIfPresent(limit, forKey: AnyKey("limit"))
        try container.encodeIfPresent(cursor, forKey: AnyKey("cursor"))
    }
}

/// A page of traces.
public struct TracePage: Decodable, Sendable, Hashable {
    public let traces: [StoredTrace]
    /// Pass in ``TraceQuery/cursor`` for the next page; `nil` on the last.
    public let cursor: String?
}

/// One trace's settled spans (pi-telemetry `StoredTrace`).
public struct StoredTrace: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { traceId }
    public let traceId: String
    public let spans: [StoredSpan]
}

/// A settled span (pi-telemetry `StoredSpan`).
public struct StoredSpan: Decodable, Sendable, Hashable, Identifiable {
    public struct Event: Decodable, Sendable, Hashable {
        public let name: String
        /// Milliseconds after the span started.
        public let timeMs: Double
        public let attributes: [String: JSONValue]
    }

    public struct Link: Decodable, Sendable, Hashable {
        public let traceId: String
        public let spanId: String
        public let attributes: [String: JSONValue]?
    }

    public let id: String
    public let traceId: String
    public let parentId: String?
    /// Such as `pi.durable.phase`.
    public let name: String
    /// Milliseconds since 1970.
    public let startedMs: Double
    public let endedMs: Double
    public let attributes: [String: JSONValue]
    public let events: [Event]
    public let links: [Link]
    /// `ok`, or `error` with ``errorMessage``.
    public let status: String
    public let errorName: String?
    public let errorMessage: String?

    public var started: Date { Date(timeIntervalSince1970: startedMs / 1000) }
    public var duration: Duration { .milliseconds(endedMs - startedMs) }

    private enum CodingKeys: String, CodingKey {
        case id, traceId, parentId, name, startedMs, endedMs, attributes, events, links, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        traceId = try container.decode(String.self, forKey: .traceId)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        name = try container.decode(String.self, forKey: .name)
        startedMs = try container.decode(Double.self, forKey: .startedMs)
        endedMs = try container.decode(Double.self, forKey: .endedMs)
        attributes = try container.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:]
        events = try container.decodeIfPresent([Event].self, forKey: .events) ?? []
        links = try container.decodeIfPresent([Link].self, forKey: .links) ?? []
        let status = try container.decodeIfPresent(JSONValue.self, forKey: .status)
        self.status = status?["status"]?.stringValue ?? "ok"
        errorName = status?["error"]?["name"]?.stringValue
        errorMessage = status?["error"]?["message"]?.stringValue
    }
}

/// Which measurements ``Telemetry/metrics(_:)`` returns (pi-telemetry `MetricQuery`).
public struct MetricQuery: Encodable, Sendable, Hashable {
    /// The metric, such as `pi.durable.phase.duration`.
    public var name: String
    public var startedAfter: Date?
    public var startedBefore: Date?
    /// Attribute values the measurements have, all of them.
    public var attributes: [String: JSONValue]?

    public init(_ name: String, startedAfter: Date? = nil, startedBefore: Date? = nil, attributes: [String: JSONValue]? = nil) {
        self.name = name
        self.startedAfter = startedAfter
        self.startedBefore = startedBefore
        self.attributes = attributes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(name, forKey: AnyKey("name"))
        try container.encodeIfPresent(startedAfter.map { $0.timeIntervalSince1970 * 1000 }, forKey: AnyKey("startMin"))
        try container.encodeIfPresent(startedBefore.map { $0.timeIntervalSince1970 * 1000 }, forKey: AnyKey("startMax"))
        try container.encodeIfPresent(attributes, forKey: AnyKey("attributes"))
    }
}

/// One metric interval (pi-telemetry `StoredMetric`).
public struct StoredMetric: Decodable, Sendable, Hashable {
    /// When the interval started, in milliseconds since 1970.
    public let intervalMs: Double
    public let name: String
    /// `counter`, `upDownCounter`, or `histogram`.
    public let kind: String
    public let unit: String?
    public let attributes: [String: JSONValue]
    public let count: Int
    public let sum: Double
    public let min: Double
    public let max: Double
}
