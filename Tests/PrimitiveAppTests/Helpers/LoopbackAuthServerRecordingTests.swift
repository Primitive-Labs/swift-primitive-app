import XCTest
import Network
@testable import PrimitiveApp

/// The recording the rpId assertions rest on: a POST body is only readable
/// once `Content-Length` bytes have arrived, and TCP is free to deliver the
/// head and the body in separate segments. A server that recorded whatever
/// came in the first `receive` would drop the body — and the rpId assertions
/// would flake rather than fail.
final class LoopbackAuthServerRecordingTests: XCTestCase {

    func testABodyArrivingInALaterSegmentIsStillRecorded() throws {
        let server = try LoopbackAuthServer()
        defer { server.stop() }
        server.on("POST /passkey/auth/start", .ok("{}"))
        try server.start()

        let body = #"{"rpId":"notes.example.com"}"#
        let head = [
            "POST /passkey/auth/start HTTP/1.1",
            "Host: 127.0.0.1",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")

        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )
        let answered = expectation(description: "server answered")
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                // A separate send after the head has been processed is a
                // separate segment on the wire.
                connection.send(content: Data(body.utf8), completion: .idempotent)
            })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                answered.fulfill()
            }
        }
        connection.start(queue: .global())
        defer { connection.cancel() }

        wait(for: [answered], timeout: 5)

        XCTAssertEqual(
            server.lastRequestJSON(matching: "POST /passkey/auth/start")?["rpId"] as? String,
            "notes.example.com"
        )
    }
}
