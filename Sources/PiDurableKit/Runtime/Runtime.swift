import CryptoKit
import Foundation
import JavaScriptCore
import os

/// A JavaScriptCore virtual machine running the bundled pi-durable.
///
/// Every ``Models`` collection and ``Harness`` lives in a runtime. Most apps use ``shared``; create
/// another runtime to isolate agents on their own JavaScript thread, or to customize networking.
public final class Runtime: Sendable {
    /// Options of a ``Runtime``.
    public struct Configuration: Sendable {
        /// The configuration of the `URLSession` that serves JavaScript `fetch()` (model provider requests).
        public var urlSessionConfiguration: URLSessionConfiguration
        /// Receives JavaScript console output. Defaults to `os.Logger`.
        public var log: (@Sendable (LogLevel, String) -> Void)?

        public init(
            urlSessionConfiguration: URLSessionConfiguration = .default,
            log: (@Sendable (LogLevel, String) -> Void)? = nil
        ) {
            self.urlSessionConfiguration = urlSessionConfiguration
            self.log = log
        }
    }

    public enum LogLevel: String, Sendable {
        case debug, info, warn, error
    }

    /// The process-wide runtime.
    public static let shared = Runtime()

    let engine: Engine

    public init(configuration: Configuration = Configuration()) {
        engine = Engine(configuration: configuration)
    }

    /// The versions of the bundled JavaScript packages, as reported by the loaded bundle.
    public func bundledVersions() async throws -> [String: String] {
        try await engine.call("versions")
    }
}

/// Owns the `JSContext` and confines it to one serial queue, which is also this actor's executor.
actor Engine {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let configuration: Runtime.Configuration
    private let logger = Logger(subsystem: "PiDurableKit", category: "JavaScript")
    private var context: JSContext?
    private var bridge: JSValue?
    private var callbacks: JSValue?
    private var loadError: Error?

    private var nextCallID = 1
    private var calls: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]
    private var hostTasks: [Int: Task<Void, Never>] = [:]
    private var streams: [Int: StreamSink] = [:]
    private var nextStreamID = 1
    private var nextObjectID = 1
    private nonisolated let sqlite = SQLiteConnections()
    private lazy var network = Network(engine: self, configuration: configuration.urlSessionConfiguration)
    private lazy var loopback = LoopbackServers(engine: self, requests: loopbackRequests)
    /// How many requests the loopback servers received.
    nonisolated let loopbackRequests = OSAllocatedUnfairLock(initialState: 0)

    let host = HostRouter()

    init(configuration: Runtime.Configuration) {
        self.configuration = configuration
        self.queue = DispatchSerialQueue(label: "PiDurableKit.JavaScript", qos: .userInitiated)
    }

    /// A fresh identifier for a JavaScript-side object (models collection, harness).
    func makeObjectID() -> Int {
        defer { nextObjectID += 1 }
        return nextObjectID
    }

    // MARK: Calls (Swift → JavaScript)

    /// Calls a bridge method and decodes its JSON result.
    func call<Result: Decodable & Sendable>(
        _ method: String,
        _ arguments: BridgeArguments = [:],
        as type: Result.Type = Result.self
    ) async throws -> Result {
        let data = try await callRaw(method, arguments)
        do {
            return try decodeJSON(Result.self, from: data)
        } catch {
            throw PiDurableError.decoding(method: method, underlying: error, json: String(decoding: data, as: UTF8.self))
        }
    }

    /// Calls a bridge method and ignores its result.
    func perform(_ method: String, _ arguments: BridgeArguments = [:]) async throws {
        _ = try await callRaw(method, arguments)
    }

    func callRaw(_ method: String, _ arguments: BridgeArguments) async throws -> Data {
        try loadIfNeeded()
        let json = try String(decoding: BridgeArguments.json(arguments), as: UTF8.self)
        let id = nextCallID
        nextCallID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                calls[id] = continuation
                bridge!.invokeMethod("call", withArguments: [id, method, json])
                reportException()
            }
        } onCancel: {
            Task { await self.cancelCall(id) }
        }
    }

    /// Calls a bridge method without waiting for it. Calls sent from one thread run in order.
    nonisolated func send(_ method: String, _ arguments: BridgeArguments) {
        queue.async {
            self.assumeIsolated { engine in
                guard (try? engine.loadIfNeeded()) != nil,
                    let data = try? BridgeArguments.json(arguments)
                else { return }
                let id = engine.nextCallID
                engine.nextCallID += 1
                engine.bridge?.invokeMethod("call", withArguments: [id, method, String(decoding: data, as: UTF8.self)])
                engine.reportException()
            }
        }
    }

    private func cancelCall(_ id: Int) {
        guard calls[id] != nil else { return }
        bridge?.invokeMethod("cancel", withArguments: [id])
        reportException()
    }

    private func reply(_ id: Int, result: String?, error: String?) {
        guard let continuation = calls.removeValue(forKey: id) else { return }
        if let error {
            continuation.resume(throwing: PiDurableError(javaScriptJSON: error))
        } else {
            continuation.resume(returning: Data((result ?? "null").utf8))
        }
    }

    // MARK: Streams (JavaScript → Swift)

    /// Opens a stream whose items JavaScript pushes with `__native.emit`; `method` attaches it on the JavaScript side.
    nonisolated func stream<Element: Decodable & Sendable>(
        _ method: String,
        _ arguments: BridgeArguments,
        of type: Element.Type = Element.self,
        bufferingPolicy: AsyncThrowingStream<Element, Error>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream(Element.self, bufferingPolicy: bufferingPolicy) { continuation in
            let handle = StreamHandle()
            Task { await self.openStream(method, arguments, handle: handle, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.stopStream(handle) }
            }
        }
    }

    private func openStream<Element: Decodable & Sendable>(
        _ method: String,
        _ arguments: BridgeArguments,
        handle: StreamHandle,
        continuation: AsyncThrowingStream<Element, Error>.Continuation
    ) async {
        guard !handle.stopped else { return }
        let id = nextStreamID
        nextStreamID += 1
        handle.id = id
        streams[id] = StreamSink(
            emit: { data in
                do {
                    continuation.yield(try decodeJSON(Element.self, from: data))
                } catch {
                    continuation.finish(throwing: PiDurableError.decoding(
                        method: method, underlying: error, json: String(decoding: data, as: UTF8.self)))
                }
            },
            finish: { error in continuation.finish(throwing: error) }
        )
        var arguments = arguments
        arguments["stream"] = id
        do {
            try await perform(method, arguments)
            if handle.stopped { try? await perform("stream.stop", ["stream": id]) }
        } catch {
            streams[id] = nil
            continuation.finish(throwing: error)
        }
    }

    private func stopStream(_ handle: StreamHandle) async {
        handle.stopped = true
        guard let id = handle.id, streams.removeValue(forKey: id) != nil else { return }
        try? await perform("stream.stop", ["stream": id])
    }

    // MARK: Host calls (JavaScript → Swift)

    private func startHostCall(id: Int, method: String, json: String) {
        let router = host
        let task = Task {
            let outcome: Result<Data?, Error>
            do {
                outcome = .success(try await router.handle(method: method, arguments: Data(json.utf8)))
            } catch {
                outcome = .failure(error)
            }
            self.finishHostCall(id: id, outcome: outcome)
        }
        hostTasks[id] = task
    }

    private func finishHostCall(id: Int, outcome: Result<Data?, Error>) {
        guard hostTasks.removeValue(forKey: id) != nil else { return }
        switch outcome {
        case .success(let data):
            let json = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            callbacks?.invokeMethod("hostResolve", withArguments: [id, json])
        case .failure(let error):
            let info: [String: String] = [
                "name": error is CancellationError ? "AbortError" : String(describing: type(of: error)),
                "message": (error as? LocalizedError)?.errorDescription ?? String(describing: error),
            ]
            let json = (try? String(decoding: JSONEncoder().encode(info), as: UTF8.self)) ?? "{}"
            callbacks?.invokeMethod("hostReject", withArguments: [id, json])
        }
        reportException()
    }

    // MARK: Loading

    private func loadIfNeeded() throws {
        if context != nil { return }
        host.attach(self)
        if let loadError { throw loadError }
        do {
            try load()
        } catch {
            loadError = error
            throw error
        }
    }

    private func load() throws {
        guard let url = Bundle.module.url(forResource: "pi-durable", withExtension: "js") else {
            throw PiDurableError.runtime("The pi-durable JavaScript bundle is missing from the PiDurableKit resources")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let context = JSContext() else { throw PiDurableError.runtime("Could not create a JavaScript context") }
        context.name = "PiDurableKit"
        #if DEBUG
        if #available(macOS 13.3, iOS 16.4, tvOS 16.4, *) { context.isInspectable = true }
        #endif
        self.context = context
        installNatives(in: context)
        context.evaluateScript(source, withSourceURL: url)
        if let exception = context.exception {
            context.exception = nil
            self.context = nil
            throw PiDurableError.runtime("Loading pi-durable failed: \(Self.describe(exception))")
        }
        bridge = context.objectForKeyedSubscript("__bridge")
        callbacks = context.objectForKeyedSubscript("__runtime")
        // The bundle captured what it needs; JavaScript extensions must not reach the host bridge (storage, files).
        let global = context.globalObject!
        for name in ["__native", "__bridge", "__runtime"] {
            global.deleteProperty(name)
        }
    }

    private func reportException() {
        guard let context, let exception = context.exception else { return }
        context.exception = nil
        log(.error, "Uncaught JavaScript exception: \(Self.describe(exception))")
    }

    static func describe(_ exception: JSValue) -> String {
        let message = exception.toString() ?? "unknown error"
        if let stack = exception.objectForKeyedSubscript("stack"), !stack.isUndefined, let text = stack.toString() {
            return "\(message)\n\(text)"
        }
        return message
    }

    nonisolated func log(_ level: Runtime.LogLevel, _ message: String) {
        if let handler = configuration.log {
            handler(level, message)
            return
        }
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warn: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    // MARK: Natives

    /// Runs `body` on this actor from a JavaScriptCore callback, which always arrives on `queue`.
    /// Like `assumeIsolated`, for closures that capture JavaScriptCore values (which never leave `queue`).
    private nonisolated func isolated<T>(_ body: (isolated Engine) throws -> T) rethrows -> T {
        dispatchPrecondition(condition: .onQueue(queue))
        return try withoutActuallyEscaping(body) { body in
            try unsafeBitCast(body, to: ((Engine) throws -> T).self)(self)
        }
    }

    private func installNatives(in context: JSContext) {
        let native = JSValue(newObjectIn: context)!
        func define(_ name: String, _ block: Any) {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }

        define("log", { [unowned self] (level: String, message: String) in
            self.log(Runtime.LogLevel(rawValue: level) ?? .info, message)
        } as @convention(block) (String, String) -> Void)

        define("now", {
            Date().timeIntervalSince1970 * 1000
        } as @convention(block) () -> Double)

        define("setTimer", { [unowned self] (id: Int, delay: Double) in
            self.isolated { $0.setTimer(id: id, delay: delay) }
        } as @convention(block) (Int, Double) -> Void)

        define("clearTimer", { [unowned self] (id: Int) in
            self.isolated { $0.timers.removeValue(forKey: id)?.cancel() }
        } as @convention(block) (Int) -> Void)

        define("randomBytes", { (array: JSValue) in
            guard let buffer = TypedArray.bytes(of: array) else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        } as @convention(block) (JSValue) -> Void)

        define("reply", { [unowned self] (id: Int, result: JSValue, error: JSValue) in
            let result: String? = result.isNull ? nil : result.toString()
            let error: String? = error.isNull ? nil : error.toString()
            self.isolated { $0.reply(id, result: result, error: error) }
        } as @convention(block) (Int, JSValue, JSValue) -> Void)

        define("hostCall", { [unowned self] (id: Int, method: String, json: String) in
            self.isolated { $0.startHostCall(id: id, method: method, json: json) }
        } as @convention(block) (Int, String, String) -> Void)

        define("hostCancel", { [unowned self] (id: Int) in
            self.isolated { $0.hostTasks[id]?.cancel() }
        } as @convention(block) (Int) -> Void)

        define("emit", { [unowned self] (id: Int, json: String) in
            self.isolated { $0.streams[id]?.emit(Data(json.utf8)) }
        } as @convention(block) (Int, String) -> Void)

        define("finish", { [unowned self] (id: Int, error: JSValue) in
            let failure: PiDurableError? = error.isNull || error.isUndefined ? nil : PiDurableError(javaScriptJSON: error.toString())
            self.isolated { engine in
                guard let sink = engine.streams.removeValue(forKey: id) else { return }
                sink.finish(failure)
            }
        } as @convention(block) (Int, JSValue) -> Void)

        define("fetchStart", { [unowned self] (id: Int, url: String, method: String, headers: String, body: JSValue) in
            var data: Data?
            if body.isString {
                data = Data(body.toString().utf8)
            } else {
                data = TypedArray.data(of: body)
            }
            let payload = data
            self.isolated { engine in
                engine.network.start(id: id, url: url, method: method, headersJSON: headers, body: payload)
            }
        } as @convention(block) (Int, String, String, String, JSValue) -> Void)

        define("fetchCancel", { [unowned self] (id: Int) in
            self.isolated { $0.network.cancel(id: id) }
        } as @convention(block) (Int) -> Void)

        let sqlite = self.sqlite
        define("sqliteOpen", { (path: String, timeout: Double) -> Int in
            do {
                return try sqlite.open(path: path, busyTimeout: timeout)
            } catch {
                Engine.throwJavaScriptError(error)
                return 0
            }
        } as @convention(block) (String, Double) -> Int)

        define("sqliteExec", { (handle: Int, sql: String) in
            do {
                try sqlite.connection(handle).execute(sql)
            } catch {
                Engine.throwJavaScriptError(error)
            }
        } as @convention(block) (Int, String) -> Void)

        define("sqliteQuery", { (handle: Int, sql: String, params: JSValue, mode: String) -> JSValue in
            let context = JSContext.current()!
            do {
                return try sqlite.connection(handle).query(sql, parameters: params, mode: mode, in: context)
            } catch {
                Engine.throwJavaScriptError(error)
                return JSValue(undefinedIn: context)
            }
        } as @convention(block) (Int, String, JSValue, String) -> JSValue)

        define("sqliteClose", { (handle: Int) in
            sqlite.close(handle)
        } as @convention(block) (Int) -> Void)

        define("createDirectory", { (path: String) in
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                Engine.throwJavaScriptError(error)
            }
        } as @convention(block) (String) -> Void)

        define("hostCallSync", { [unowned self] (method: String, json: String) -> String in
            self.host.handleSync(method: method, arguments: Data(json.utf8))
        } as @convention(block) (String, String) -> String)

        func fileOperation<T>(_ body: () throws -> T, fallback: T) -> T {
            do {
                return try body()
            } catch {
                Engine.throwJavaScriptError(error)
                return fallback
            }
        }

        define("fsStat", { (path: String, follow: Bool) -> String in
            fileOperation({ try FileOperations.statJSON(path, follow: follow) }, fallback: "{}")
        } as @convention(block) (String, Bool) -> String)

        define("fsReadFile", { (path: String) -> JSValue in
            let context = JSContext.current()!
            return fileOperation({
                TypedArray.makeUint8Array(try FileOperations.read(path), in: context) ?? JSValue(undefinedIn: context)
            }, fallback: JSValue(undefinedIn: context))
        } as @convention(block) (String) -> JSValue)

        define("fsReadRange", { (path: String, offset: Double, length: Double) -> JSValue in
            let context = JSContext.current()!
            return fileOperation({
                TypedArray.makeUint8Array(
                    try FileOperations.read(path, offset: Int(offset), length: Int(length)), in: context)
                    ?? JSValue(undefinedIn: context)
            }, fallback: JSValue(undefinedIn: context))
        } as @convention(block) (String, Double, Double) -> JSValue)

        define("fsWrite", { (path: String, content: JSValue, append: Bool) in
            let data = content.isString ? Data(content.toString().utf8) : (TypedArray.data(of: content) ?? Data())
            fileOperation({ try FileOperations.write(path, data, append: append) }, fallback: ())
        } as @convention(block) (String, JSValue, Bool) -> Void)

        define("fsTruncate", { (path: String, size: Double) in
            fileOperation({ try FileOperations.truncate(path, size: Int(size)) }, fallback: ())
        } as @convention(block) (String, Double) -> Void)

        define("fsSync", { (path: String) in
            fileOperation({ try FileOperations.sync(path) }, fallback: ())
        } as @convention(block) (String) -> Void)

        define("fsRename", { (source: String, destination: String) in
            fileOperation({ try FileOperations.rename(source, destination) }, fallback: ())
        } as @convention(block) (String, String) -> Void)

        define("fsList", { (path: String) -> String in
            fileOperation({ try FileOperations.list(path) }, fallback: "[]")
        } as @convention(block) (String) -> String)

        define("fsMkdir", { (path: String, recursive: Bool) in
            fileOperation({ try FileOperations.makeDirectory(path, recursive: recursive) }, fallback: ())
        } as @convention(block) (String, Bool) -> Void)

        define("fsRemove", { (path: String, recursive: Bool, force: Bool) in
            fileOperation({ try FileOperations.remove(path, recursive: recursive, force: force) }, fallback: ())
        } as @convention(block) (String, Bool, Bool) -> Void)

        define("fsRealpath", { (path: String) -> String in
            fileOperation({ try FileOperations.realPath(path) }, fallback: path)
        } as @convention(block) (String) -> String)

        define("sha256", { (bytes: JSValue) -> JSValue in
            let context = JSContext.current()!
            let digest = Data(SHA256.hash(data: TypedArray.data(of: bytes) ?? Data()))
            return TypedArray.makeUint8Array(digest, in: context) ?? JSValue(undefinedIn: context)
        } as @convention(block) (JSValue) -> JSValue)

        define("httpListen", { [unowned self] (server: Int, port: Int) in
            self.isolated { $0.loopback.listen(server: server, port: port) }
        } as @convention(block) (Int, Int) -> Void)

        define("httpRespond", { [unowned self] (connection: Int, status: Int, headers: String, body: String) in
            self.isolated { $0.loopback.respond(connection: connection, status: status, headersJSON: headers, body: body) }
        } as @convention(block) (Int, Int, String, String) -> Void)

        define("httpClose", { [unowned self] (server: Int) in
            self.isolated { $0.loopback.close(server: server) }
        } as @convention(block) (Int) -> Void)

        define("httpCloseConnections", { [unowned self] (server: Int) in
            self.isolated { $0.loopback.closeConnections(server: server) }
        } as @convention(block) (Int) -> Void)

        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    static func throwJavaScriptError(_ error: Error) {
        guard let context = JSContext.current() else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let exception = JSValue(newErrorFromMessage: message, in: context)
        if let error = error as? FileOperationError {
            exception?.setValue(error.code, forProperty: "code")
        }
        context.exception = exception
    }

    /// A delay `Int(_:)` accepts. JavaScript can pass Infinity, NaN, or a huge delay, and `Int(_:)` traps on those.
    static func timerDelay(_ delay: Double) -> Double {
        delay.isNaN ? 0 : min(max(0, delay), Double(Int32.max))
    }

    private func setTimer(id: Int, delay: Double) {
        timers[id]?.cancel()
        let delay = Self.timerDelay(delay)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isolated { engine in
                guard engine.timers.removeValue(forKey: id) != nil else { return }
                engine.callbacks?.invokeMethod("fireTimer", withArguments: [id])
                engine.reportException()
            }
        }
        timers[id] = item
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay)), execute: item)
    }

    // MARK: Network callbacks

    func deliverResponse(id: Int, status: Int, statusText: String, url: String, headersJSON: String) {
        callbacks?.invokeMethod("fetchResponse", withArguments: [id, status, statusText, url, headersJSON])
        reportException()
    }

    func deliverData(id: Int, data: Data) {
        guard let context, let array = TypedArray.makeUint8Array(data, in: context) else { return }
        callbacks?.invokeMethod("fetchData", withArguments: [id, array])
        reportException()
    }

    func deliverEnd(id: Int) {
        callbacks?.invokeMethod("fetchEnd", withArguments: [id])
        reportException()
    }

    func deliverHTTPListening(server: Int, port: Int) {
        callbacks?.invokeMethod("httpListening", withArguments: [server, port])
        reportException()
    }

    func deliverHTTPFailed(server: Int, message: String) {
        callbacks?.invokeMethod("httpFailed", withArguments: [server, message])
        reportException()
    }

    func deliverHTTPRequest(server: Int, connection: Int, method: String, url: String, headersJSON: String) {
        callbacks?.invokeMethod("httpRequest", withArguments: [server, connection, method, url, headersJSON])
        reportException()
    }

    func deliverError(id: Int, message: String) {
        callbacks?.invokeMethod("fetchError", withArguments: [id, message])
        reportException()
    }
}

/// Receives the items of one JavaScript-pushed stream. Only touched on the engine's executor.
struct StreamSink {
    let emit: (Data) -> Void
    let finish: (Error?) -> Void
}

/// Identifies one stream across its opening and its termination. Only touched on the engine's executor.
final class StreamHandle: @unchecked Sendable {
    var id: Int?
    var stopped = false
}
