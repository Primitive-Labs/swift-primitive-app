import Foundation
import Network

/// A loopback TCP relay in front of the live dev server that can hold a
/// WebSocket upgrade or a request, so a test decides when the real client's
/// connect completes or a response arrives — the way a slow network does —
/// while everything else keeps flowing.
///
/// Every connection is relayed byte for byte to the upstream server, except:
///
/// - a connection whose first request asks for a WebSocket upgrade while
///   upgrades are held: it is parked, unsent, until `releaseUpgrades()`. The
///   client opens each socket in a fresh `URLSession`, so an upgrade is
///   always the first request on its connection;
/// - a request whose bytes contain the held pattern: it is parked, unsent,
///   until `releaseHeldRequests()`.
final class LoopbackRelay: @unchecked Sendable {
    private let listener: NWListener
    private let upstreamHost: NWEndpoint.Host
    private let upstreamPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "loopback-relay")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var holdsUpgrades = false
    private var parkedUpgrades: [(client: NWConnection, firstBytes: Data)] = []
    private var upgradesHeld = 0
    private var heldPattern: Data?
    private var parked: [(data: Data, from: NWConnection, to: NWConnection)] = []

    /// Relays to the origin of `upstream`, e.g. `http://127.0.0.1:8787`.
    init(upstream: String) throws {
        guard let url = URL(string: upstream), let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw NSError(
                domain: "LoopbackRelay", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "bad upstream \(upstream)"]
            )
        }
        upstreamHost = NWEndpoint.Host(host)
        upstreamPort = port
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Park every WebSocket upgrade until `releaseUpgrades()`: the client's
    /// connect stays in flight.
    func holdUpgrades() {
        lock.withLock { holdsUpgrades = true }
    }

    /// How many upgrades the relay has held so far.
    var heldUpgrades: Int { lock.withLock { upgradesHeld } }

    /// Stop holding upgrades, and send every parked one on its way.
    func releaseUpgrades() {
        let released = lock.withLock {
            holdsUpgrades = false
            defer { parkedUpgrades.removeAll() }
            return parkedUpgrades
        }
        for item in released {
            relay(item.client, firstBytes: item.firstBytes)
        }
    }

    /// Park every request whose bytes contain `pattern` (e.g. a path) until
    /// `releaseHeldRequests()`.
    func holdRequests(containing pattern: String) {
        lock.withLock { heldPattern = Data(pattern.utf8) }
    }

    /// How many requests are parked right now.
    var heldRequests: Int { lock.withLock { parked.count } }

    /// Stop holding, and send every parked request on its way.
    func releaseHeldRequests() {
        let released = lock.withLock {
            heldPattern = nil
            defer { parked.removeAll() }
            return parked
        }
        for item in released {
            forward(item.data, from: item.from, to: item.to)
        }
    }

    /// Starts the listener and blocks until it is ready (bounded), returning
    /// the relay's loopback origin (no trailing slash).
    @discardableResult
    func start() throws -> String {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.track(connection)
            connection.start(queue: self.queue)
            self.readHead(of: connection, buffer: Data())
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(
                domain: "LoopbackRelay", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"]
            )
        }
        return "http://127.0.0.1:\(listener.port?.rawValue ?? 0)"
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - Relaying

    private func track(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
    }

    /// Reads up to the end of the first request's head, then decides.
    private func readHead(of client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return client.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if isComplete { return client.cancel() }
                return self.readHead(of: client, buffer: buffer)
            }
            let head = String(decoding: buffer, as: UTF8.self).lowercased()
            let isUpgrade = head.contains("upgrade: websocket")
            let held = self.lock.withLock { () -> Bool in
                guard isUpgrade, self.holdsUpgrades else { return false }
                self.parkedUpgrades.append((client, buffer))
                self.upgradesHeld += 1
                return true
            }
            if !held { self.relay(client, firstBytes: buffer) }
        }
    }

    private func relay(_ client: NWConnection, firstBytes: Data) {
        let upstream = NWConnection(host: upstreamHost, port: upstreamPort, using: .tcp)
        track(upstream)
        upstream.start(queue: queue)
        forward(firstBytes, from: client, to: upstream)
        pump(from: upstream, to: client)
    }

    /// Send a request chunk upstream and keep reading — unless it is held, in
    /// which case it waits, and nothing after it on that connection moves.
    private func forward(_ data: Data, from client: NWConnection, to upstream: NWConnection) {
        let held = lock.withLock { () -> Bool in
            guard let pattern = heldPattern, data.range(of: pattern) != nil else { return false }
            parked.append((data, client, upstream))
            return true
        }
        if held { return }
        upstream.send(content: data, completion: .contentProcessed { _ in })
        pump(from: client, to: upstream, isRequest: true)
    }

    /// Relays `source` to `destination` until either side ends. Upstream
    /// responses go straight through; client requests go through `forward`,
    /// which may hold them.
    private func pump(from source: NWConnection, to destination: NWConnection, isRequest: Bool = false) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            let ended = isComplete || error != nil
            if let data, !data.isEmpty {
                if isRequest && !ended {
                    // `forward` resumes this pump once the chunk is sent.
                    self?.forward(data, from: source, to: destination)
                    return
                }
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if ended {
                // Half-close is not modelled: one side ending ends both.
                source.cancel()
                destination.cancel()
                return
            }
            self?.pump(from: source, to: destination, isRequest: isRequest)
        }
    }
}
