#if DEBUG
import Foundation
import Network

/// Minimal HTTP/1.1 server built on Network.framework, supporting plain responses and
/// Server-Sent Events (SSE) streams. Scoped to the inspector's needs — no keep-alive,
/// no content negotiation, no WebSocket. GET only.
///
/// Flow: NWListener accepts a connection → we read until the request headers end (\r\n\r\n)
/// → parse the request line and query string → hand a Request + ResponseWriter to the router
/// → the route either writes one response and closes, or opens an SSE channel and keeps the
/// connection alive while frames are pushed in.
final class DebugHTTPServer {

    // MARK: - Types

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    typealias Router = (Request, ResponseWriter) -> Void

    // MARK: - State

    private let port: UInt16
    private let router: Router
    private let bonjourName: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.primitivelabs.DebugHTTPServer")

    init(port: UInt16, bonjourName: String? = nil, router: @escaping Router) {
        self.port = port
        self.bonjourName = bonjourName
        self.router = router
    }

    // MARK: - Lifecycle

    func start(onStateChange: @escaping (NWListener.State) -> Void = { _ in }) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        // Advertise via Bonjour on iOS — without this, iOS never shows the Local Network
        // permission prompt and silently drops inbound data from peers on the Wi-Fi LAN.
        // The `name` is the instance name shown to browsers; `type` must match one of the
        // service types declared in the app's NSBonjourServices Info.plist key.
        if let bonjourName {
            listener.service = NWListener.Service(name: bonjourName, type: "_primitive-inspector._tcp")
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = onStateChange
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }

            // HTTP request headers end with a blank line. Until we see that, keep reading.
            if let headerEnd = next.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = next.subdata(in: 0..<headerEnd.lowerBound)
                let bodyStart = headerEnd.upperBound
                let alreadyReadBody = next.subdata(in: bodyStart..<next.count)
                self.parseAndRead(headerData: headerData, alreadyReadBody: alreadyReadBody, connection: connection)
                return
            }
            if isComplete || next.count > 64_000 {
                connection.cancel()
                return
            }
            self.readRequest(on: connection, buffer: next)
        }
    }

    /// Parse request headers, determine Content-Length, keep draining bytes until we have the
    /// full body, then dispatch. POST /api/action/* calls send a small JSON body — we cap at
    /// 256KB as a defensive ceiling.
    private func parseAndRead(headerData: Data, alreadyReadBody: Data, connection: NWConnection) {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            writeRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", on: connection, then: .close)
            return
        }
        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first else {
            writeRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", on: connection, then: .close)
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            writeRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", on: connection, then: .close)
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])
        guard method == "GET" || method == "POST" || method == "OPTIONS" else {
            writeRaw("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n", on: connection, then: .close)
            return
        }
        // CORS preflight — answer it here so the browser lets the real POST through.
        if method == "OPTIONS" {
            let resp = """
            HTTP/1.1 204 No Content\r
            Access-Control-Allow-Origin: *\r
            Access-Control-Allow-Methods: GET, POST, OPTIONS\r
            Access-Control-Allow-Headers: Content-Type\r
            Access-Control-Max-Age: 600\r
            Content-Length: 0\r
            \r

            """
            writeRaw(resp, on: connection, then: .close)
            return
        }

        var contentLength = 0
        for line in lines.dropFirst() {
            let l = line.lowercased()
            if l.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }
        }
        // Some sensible ceiling.
        guard contentLength <= 256 * 1024 else {
            writeRaw("HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n", on: connection, then: .close)
            return
        }

        if alreadyReadBody.count >= contentLength {
            let body = alreadyReadBody.prefix(contentLength)
            dispatch(method: method, target: target, body: Data(body), connection: connection)
            return
        }
        // Body hasn't fully arrived — keep draining until we have all of it.
        readBody(on: connection, need: contentLength, buffer: alreadyReadBody, method: method, target: target)
    }

    private func readBody(on connection: NWConnection, need: Int, buffer: Data, method: String, target: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if next.count >= need {
                let body = next.prefix(need)
                self.dispatch(method: method, target: target, body: Data(body), connection: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.readBody(on: connection, need: need, buffer: next, method: method, target: target)
        }
    }

    private func dispatch(method: String, target: String, body: Data, connection: NWConnection) {
        let (path, query) = Self.parseTarget(target)
        let request = Request(method: method, path: path, query: query, body: body)
        let writer = ResponseWriter(connection: connection, queue: queue)
        router(request, writer)
    }

    private static func parseTarget(_ target: String) -> (String, [String: String]) {
        guard let qIdx = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<qIdx])
        let queryString = target[target.index(after: qIdx)...]
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            query[k] = v
        }
        return (path, query)
    }

    enum PostWrite {
        case close
        case keepOpen
    }

    fileprivate func writeRaw(_ text: String, on connection: NWConnection, then: PostWrite) {
        let data = Data(text.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            if case .close = then { connection.cancel() }
        })
    }
}

// MARK: - ResponseWriter + SSE

/// Hands a routed request one of two outcomes: a single HTTP response, or an SSE channel
/// that the caller keeps alive and pushes frames through.
final class ResponseWriter {
    fileprivate let connection: NWConnection
    fileprivate let queue: DispatchQueue
    private var consumed = false

    fileprivate init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func respond(status: Int = 200, contentType: String, body: Data,
                 extraHeaders: [String: String] = [:]) {
        guard !consumed else { return }
        consumed = true
        let statusText = Self.statusText(status)
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        for (k, v) in extraHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var packet = Data(head.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    func respondJSON(_ object: Any, status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        respond(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    func respondText(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") {
        respond(status: status, contentType: contentType, body: Data(text.utf8))
    }

    func notFound() {
        respondText("Not Found", status: 404)
    }

    /// Switches the connection to SSE mode. Sends the headers, returns a channel that the
    /// caller drives by calling `.send(...)` when events arrive. The connection stays open
    /// until the channel is closed or the peer disconnects.
    func startSSE() -> SSEChannel {
        assert(!consumed, "ResponseWriter already used")
        consumed = true
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream; charset=utf-8\r
        Cache-Control: no-store\r
        Connection: keep-alive\r
        Access-Control-Allow-Origin: *\r
        X-Accel-Buffering: no\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let channel = SSEChannel(connection: connection, queue: queue)
        channel.startLivenessWatch()
        return channel
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 400: return "Bad Request"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

/// A single SSE subscription. Thread-safe sends; silently no-ops once closed.
final class SSEChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false

    let id = UUID()

    fileprivate init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// Send a JSON event frame. Single-line frames only — the JSON encoder already
    /// escapes newlines, so the SSE `data: ...\n\n` framing is safe.
    func sendEvent(name: String, jsonData: String) {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }
        let frame = "event: \(name)\ndata: \(jsonData)\n\n"
        connection.send(content: Data(frame.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { connection.cancel() }
    }

    /// Observe the connection state so we notice when the browser tab closes or the
    /// client walks away, and mark ourselves closed so event pushes stop silently.
    fileprivate func startLivenessWatch() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.close()
            default:
                break
            }
        }
    }
}
#endif
