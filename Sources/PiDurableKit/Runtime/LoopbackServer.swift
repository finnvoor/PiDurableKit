import Foundation
import Network
import os

/// Loopback HTTP servers for the `node:http` shim: they receive OAuth redirects from the sign-in page.
///
/// Bound to the loopback interface only. Each connection serves one request and closes. Only used on the engine's
/// queue, except ``requestCount``.
final class LoopbackServers: @unchecked Sendable {
    private unowned let engine: Engine
    private var listeners: [Int: NWListener] = [:]
    private var connections: [Int: (server: Int, connection: NWConnection)] = [:]
    private var nextConnection = 1
    private let requests: OSAllocatedUnfairLock<Int>

    /// - Parameter requests: Counts received requests; sign-in uses it to tell a finished redirect from a dismissal.
    init(engine: Engine, requests: OSAllocatedUnfairLock<Int>) {
        self.engine = engine
        self.requests = requests
    }

    func listen(server: Int, port: Int) {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any)
        } catch {
            failed(server: server, message: "listen failed on port \(port): \(error.localizedDescription)")
            return
        }
        listeners[server] = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = Int(listener?.port?.rawValue ?? 0)
                self.engine.assumeIsolated { $0.deliverHTTPListening(server: server, port: port) }
            case .failed(let error):
                self.listeners[server] = nil
                self.failed(server: server, message: "listen failed on port \(port): \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, server: server)
        }
        listener.start(queue: engine.queue)
    }

    private func failed(server: Int, message: String) {
        engine.queue.async { [engine] in
            engine.assumeIsolated { $0.deliverHTTPFailed(server: server, message: message) }
        }
    }

    func close(server: Int) {
        listeners.removeValue(forKey: server)?.cancel()
    }

    func closeConnections(server: Int) {
        for (id, entry) in connections where entry.server == server {
            entry.connection.cancel()
            connections[id] = nil
        }
    }

    private func accept(_ connection: NWConnection, server: Int) {
        let id = nextConnection
        nextConnection += 1
        connections[id] = (server, connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: engine.queue)
        receive(connection, id: id, server: server, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: Int, server: Int, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(head: buffer[..<end.lowerBound], connection: id, server: server)
            } else if error != nil || isComplete || buffer.count > 1 << 20 {
                connection.cancel()
            } else {
                self.receive(connection, id: id, server: server, buffer: buffer)
            }
        }
    }

    private func handle(head: Data, connection: Int, server: Int) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else {
            respond(connection: connection, status: 400, headersJSON: "{}", body: "")
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        requests.withLock { $0 += 1 }
        let json = (try? String(decoding: JSONEncoder().encode(headers), as: UTF8.self)) ?? "{}"
        engine.assumeIsolated {
            $0.deliverHTTPRequest(
                server: server, connection: connection, method: String(parts[0]), url: String(parts[1]), headersJSON: json)
        }
    }

    func respond(connection id: Int, status: Int, headersJSON: String, body: String) {
        guard let connection = connections[id]?.connection else { return }
        let headers = (try? JSONDecoder().decode([String: String].self, from: Data(headersJSON.utf8))) ?? [:]
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for (name, value) in headers where name != "content-length" && name != "connection" {
            head += "\(name): \(value)\r\n"
        }
        head += "content-length: \(bodyData.count)\r\nconnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections[id] = nil
        })
    }
}
