import Foundation
import Testing
@testable import PiDurableKit

/// A harness over a fresh faux provider.
struct FauxSetup {
    let models: Models
    let faux: FauxProvider
    let harness: Harness

    static func make(
        _ storage: Storage = .memory,
        extensions: [Extension] = [],
        settings: Settings = Settings(),
        tokensPerSecond: Double? = nil,
        runtime: Runtime = .shared
    ) async throws -> FauxSetup {
        let models = Models(builtinProviders: false, runtime: runtime)
        let faux = FauxProvider(tokensPerSecond: tokensPerSecond)
        try await models.register(faux)
        let harness = try await Harness.open(storage, models: models, extensions: extensions, settings: settings)
        return FauxSetup(models: models, faux: faux, harness: harness)
    }

    func root(_ change: AgentChange = AgentChange()) async throws -> Conversation {
        var change = change
        change.model = change.model ?? faux.model
        return try await harness.root(agent: change)
    }
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "PiDurableKitTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Serves canned HTTP responses to the runtime's `fetch()`, streaming bodies in chunks.
final class MockServer: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var headers = ["content-type": "text/event-stream"]
        var chunks: [String]
    }

    struct Request: Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
        var json: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: body) }
        /// A header, by case-insensitive name.
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    nonisolated(unsafe) private static var handlers: [String: @Sendable (Request) -> Response] = [:]
    nonisolated(unsafe) private(set) static var requests: [Request] = []
    private static let lock = NSLock()

    static func handle(host: String, _ handler: @escaping @Sendable (Request) -> Response) {
        lock.withLock { handlers[host] = handler }
    }

    static func requests(to host: String) -> [Request] {
        lock.withLock { requests.filter { $0.url.host() == host } }
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockServer.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let recorded = Request(
            url: request.url!, method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:], body: body)
        let handler = Self.lock.withLock {
            Self.requests.append(recorded)
            return Self.handlers[request.url!.host() ?? ""]
        }
        let response = handler?(recorded) ?? Response(status: 404, headers: [:], chunks: ["not found"])
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        let client = client
        Task {
            for chunk in response.chunks {
                try? await Task.sleep(for: .milliseconds(5))
                client?.urlProtocol(self, didLoad: Data(chunk.utf8))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

extension String {
    /// One server-sent event.
    static func sse(_ json: String, event: String? = nil) -> String {
        (event.map { "event: \($0)\n" } ?? "") + "data: \(json)\n\n"
    }
}

struct TimeoutError: Error {}

/// Runs `operation`, failing after `seconds` instead of hanging the test run.
func withTimeout<T: Sendable>(
    _ seconds: Double = 10, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Suites that share `MockServer`'s hosts, run one at a time.
@Suite(.serialized) enum MockServerTests {}

/// An input that was not answered.
struct Unanswered: Error, CustomStringConvertible {
    let record: SubmissionRecord
    var description: String { "Unanswered: \(record.status)" }
}

/// pi-durable's quick start: submit input, wait for it to settle, then read the answer entry in a commit.
func ask(_ conversation: Conversation, _ text: String) async throws -> AssistantMessage {
    try await answer(of: try await conversation.submit(text))
}

func answer(of submission: Submission) async throws -> AssistantMessage {
    let settled = try await submission.wait()
    guard case .done(_, let id?) = settled.status else { throw Unanswered(record: settled) }
    let entry = try await submission.harness.commit { tx in try await tx.entry(id) }
    return try #require(entry?.assistantMessage)
}
