import Foundation
import Network

/// Minimal in-process HTTP/1.1 server that answers the handful of auth
/// endpoints `PrimitiveAuthManager` calls, so a sign-in failure can be driven
/// through the REAL client path — transport, `HttpError` body parsing, the
/// manager's catch block — without a dev server.
///
/// Same shape as the swift-client package's `LoopbackHTTPServer`: an
/// `NWListener` on a loopback port, started and stopped by the test. Routing is
/// by substring of the request line, and anything unmatched gets a 404, so a
/// suite only scripts the endpoint it cares about.
final class LoopbackAuthServer: @unchecked Sendable {
    /// One canned answer: the status line and the JSON body.
    struct Reply: Sendable {
        var status: Int
        var json: String

        static func ok(_ json: String) -> Reply { Reply(status: 200, json: json) }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-auth-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var routes: [(match: String, reply: Reply)] = []

    /// The loopback port the server is listening on, valid after `start()`.
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Script one endpoint. `match` is matched against the request line, e.g.
    /// `"POST /auth/email/request"` or just `"/oauth-config"`.
    func on(_ match: String, _ reply: Reply) {
        lock.withLock { routes.append((match, reply)) }
    }

    /// Starts the listener and blocks until it is ready (bounded), returning
    /// the bound loopback origin (no trailing slash).
    @discardableResult
    func start() throws -> String {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.answer(connection)
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(
                domain: "LoopbackAuthServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"]
            )
        }
        port = listener.port?.rawValue ?? 0
        return "http://127.0.0.1:\(port)"
    }

    private func reply(forRequestLine line: String) -> Reply {
        let match = lock.withLock { routes.first { line.contains($0.match) } }
        return match?.reply
            ?? Reply(status: 404, json: #"{"error":"unrouted in LoopbackAuthServer"}"#)
    }

    /// Reads the request head, writes the scripted response, then closes —
    /// `Connection: close` is what tells URLSession the body is complete.
    private func answer(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, _, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            let requestLine = data
                .flatMap { String(data: $0, encoding: .utf8) }?
                .components(separatedBy: "\r\n").first ?? ""
            let reply = self.reply(forRequestLine: requestLine)
            let body = Data(reply.json.utf8)

            var head = "HTTP/1.1 \(reply.status) \(Self.reason(reply.status))\r\n"
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"

            var response = Data(head.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        default: return "Status"
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }
}
