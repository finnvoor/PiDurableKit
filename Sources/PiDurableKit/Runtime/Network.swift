import Foundation

/// Serves JavaScript `fetch()` with `URLSession`, streaming response bodies as they arrive.
///
/// Delegate callbacks run on the engine's queue, so every delivery is ordered and isolated to the engine.
final class Network: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private unowned let engine: Engine
    private var session: URLSession!
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var ids: [Int: Int] = [:] // task identifier → fetch id

    init(engine: Engine, configuration: URLSessionConfiguration) {
        self.engine = engine
        super.init()
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = engine.queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func start(id: Int, url: String, method: String, headersJSON: String, body: Data?) {
        guard let url = URL(string: url) else {
            fail(id: id, message: "Invalid URL \(url)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60 * 60
        let headers = (try? JSONDecoder().decode([[String]].self, from: Data(headersJSON.utf8))) ?? []
        for pair in headers where pair.count == 2 {
            request.addValue(pair[1], forHTTPHeaderField: pair[0])
        }
        let task = session.dataTask(with: request)
        tasks[id] = task
        ids[task.taskIdentifier] = id
        task.resume()
    }

    func cancel(id: Int) {
        guard let task = tasks.removeValue(forKey: id) else { return }
        ids[task.taskIdentifier] = nil
        task.cancel()
    }

    private func fail(id: Int, message: String) {
        engine.queue.async { [engine] in
            engine.assumeIsolated { $0.deliverError(id: id, message: message) }
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let id = ids[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        var headers: [[String]] = []
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers.append(["\(key)", "\(value)"])
        }
        let json = (try? String(decoding: JSONEncoder().encode(headers), as: UTF8.self)) ?? "[]"
        let statusText = HTTPURLResponse.localizedString(forStatusCode: status)
        engine.assumeIsolated {
            $0.deliverResponse(
                id: id, status: status, statusText: statusText, url: response.url?.absoluteString ?? "", headersJSON: json)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = ids[dataTask.taskIdentifier] else { return }
        engine.assumeIsolated { $0.deliverData(id: id, data: data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = ids.removeValue(forKey: task.taskIdentifier) else { return }
        tasks[id] = nil
        if let error {
            engine.assumeIsolated { $0.deliverError(id: id, message: error.localizedDescription) }
        } else {
            engine.assumeIsolated { $0.deliverEnd(id: id) }
        }
    }
}
