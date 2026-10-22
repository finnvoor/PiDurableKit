import Foundation

/// A failure that didn't fail the operation that ran into it, for ``Harness/open(_:models:extensions:settings:environment:resume:onConversationCreated:clock:timer:onWake:onReport:identity:telemetry:)``'s
/// `onReport` (pi-durable `onReport(error, info)`): what went wrong, and what it was about.
public struct HarnessReport: Sendable, Hashable, CustomStringConvertible {
    /// The error's message.
    public let message: String
    /// What happened.
    public let kind: Kind

    /// What a report is about (pi-durable `ReportInfo`).
    public enum Kind: Sendable, Hashable {
        /// The error failed the harness's session, which closes: a storage error, often a platform reset.
        case sessionFailed
        /// The task ended faulted: its phase threw, or its abort handler was cut off ``Settings/restartLimit`` times.
        case taskFaulted(ReportTask, extension: String?, restartLimit: Bool)
        /// The restart limit parked the task until ``Harness/retryTask(_:)``.
        case taskParked(ReportTask, extension: String?)
        /// The task's stored state couldn't be migrated; it is blocked until the installed task types change.
        case migrationFailed(ReportTask, extension: String?)
        /// A running task keeps running under its old definition, which was uninstalled (`missingTask`) or replaced by
        /// one that can't take over its state.
        case taskOutdated(ReportTask, extension: String?, missingTask: Bool)
        /// The task's own ``TaskRun/report(_:from:)``, or a failure running it.
        case taskError(ReportTask, extension: String?)
        /// A hook, section, wrap, or a tool's invalid structured output failed: with the task that ran it, or outside a
        /// task the conversation whose agent was resolved.
        case extensionError(extension: String?, task: ReportTask?, conversation: ConversationID?)
        /// A host callback threw, such as the clock or the environment builder; with the task that called it.
        case hostError(callback: HostCallback, task: ReportTask?)
        /// A commit, close, watch, view, or document listener threw.
        case listenerError
    }

    public var description: String { message }

    init(message: String, info: JSONValue?) {
        self.message = message
        let task = info?["task"].flatMap(ReportTask.init(json:))
        let `extension` = info?["extension"]?.stringValue
        switch info?["type"]?.stringValue {
        case "session_failed": kind = .sessionFailed
        case "task_faulted" where task != nil:
            kind = .taskFaulted(task!, extension: `extension`, restartLimit: info?["reason"]?.stringValue == "restart_limit")
        case "task_parked" where task != nil: kind = .taskParked(task!, extension: `extension`)
        case "migration_failed" where task != nil: kind = .migrationFailed(task!, extension: `extension`)
        case "task_outdated" where task != nil:
            kind = .taskOutdated(task!, extension: `extension`, missingTask: info?["reason"]?.stringValue == "missing_task")
        case "task_error" where task != nil: kind = .taskError(task!, extension: `extension`)
        case "extension_error":
            kind = .extensionError(
                extension: `extension`, task: task, conversation: info?["conversationId"]?.intValue.map { ConversationID($0) })
        case "host_error":
            kind = .hostError(callback: HostCallback(rawValue: info?["callback"]?.stringValue ?? ""), task: task)
        default: kind = .listenerError
        }
    }
}

/// The task a ``HarnessReport`` is about (pi-durable `ReportTask`).
public struct ReportTask: Sendable, Hashable {
    public let id: TaskID
    /// The task's registered name, such as `pi.generation`.
    public let kind: String
    public let conversationId: ConversationID

    init?(json: JSONValue) {
        guard let id = json["id"]?.intValue, let kind = json["kind"]?.stringValue,
            let conversation = json["conversationId"]?.intValue
        else { return nil }
        self.id = TaskID(id)
        self.kind = kind
        self.conversationId = ConversationID(conversation)
    }
}

/// A host callback a ``HarnessReport`` names (pi-durable `HostCallback`).
public struct HostCallback: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// The harness clock.
    public static let now = HostCallback(rawValue: "now")
    public static let settings = HostCallback(rawValue: "settings")
    public static let registry = HostCallback(rawValue: "registry")
    /// The environment builder.
    public static let environment = HostCallback(rawValue: "env")
    /// A model provider call.
    public static let models = HostCallback(rawValue: "models")
    /// The harness timer.
    public static let timer = HostCallback(rawValue: "setTimer")
    /// The wake callback.
    public static let onWake = HostCallback(rawValue: "onWake")
}

/// Whose code a task's ``TaskRun/report(_:from:)`` is about when not the task's own (pi-durable `ReportFrom`).
public enum ReportSource: Sendable, Hashable, Encodable {
    /// Extension code the task called, such as a section; its extension, if known.
    case `extension`(String?)
    /// A host callback the task called, such as the environment builder.
    case host(HostCallback)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .extension(let name):
            try container.encode("extension", forKey: AnyKey("type"))
            try container.encodeIfPresent(name, forKey: AnyKey("extension"))
        case .host(let callback):
            try container.encode("host", forKey: AnyKey("type"))
            try container.encode(callback.rawValue, forKey: AnyKey("callback"))
        }
    }
}

/// When a harness next needs a running process (pi-durable `Wake`), from ``Harness/wake()`` or `onWake`.
public struct Wake: Sendable, Hashable, Decodable {
    /// Whether some task can run now or is running, or recovery hasn't finished: a process that dies must be woken soon.
    public let active: Bool
    /// The earliest sleep not yet due, if any.
    public let at: Date?

    private enum CodingKeys: String, CodingKey { case active, at }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        at = try container.decodeIfPresent(Double.self, forKey: .at).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// Opaque, JSON-serializable telemetry propagation data a ``Telemetry`` recorder stores with tasks and submissions
/// (pi-telemetry `TelemetryCarrier`).
public typealias TelemetryCarrier = [String: String]

/// Where a new task's telemetry continues (pi-durable `TaskOptions.trace`).
public enum TaskTrace: Sendable, Hashable {
    /// The creator's trace (the default).
    case inherited
    /// A new trace at the recorder's root.
    case root
    /// The trace a carrier names.
    case carrier(TelemetryCarrier)

    var json: JSONValue? {
        switch self {
        case .inherited: nil
        case .root: "root"
        case .carrier(let carrier): .object(carrier.mapValues { .string($0) })
        }
    }
}
