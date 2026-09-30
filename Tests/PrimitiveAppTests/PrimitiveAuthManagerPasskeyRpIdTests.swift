import XCTest
@testable import PrimitiveApp
import JsBaoClient

/// Issue #3080 — passkey ceremonies run against a named relying party
/// WITHOUT leaving the manager.
///
/// Calling `client.auth.signInWithPasskey(rpId:)` directly was already
/// possible; it just skipped the manager's `loginState` / `isAuthenticating` /
/// `authFailure` bookkeeping and its on-device passkey hint. So the per-call
/// route has to exist on the manager, and everything the manager does around a
/// ceremony has to keep happening for both values of the argument.
///
/// Driven through the REAL client path against a loopback server that records
/// what was sent: a passkey ceremony fails at the HTTP start call, before any
/// `ASAuthorizationController` exists, so this runs headless.
@MainActor
final class PrimitiveAuthManagerPasskeyRpIdTests: XCTestCase {

    /// What the server answers when the named relying party is not one of the
    /// app's configured ones — the typed rejection the migration note in the
    /// docs points at.
    private static let rpNotConfigured =
        #"{"error":"Passkeys are not configured for this app","code":"PASSKEY_RP_NOT_CONFIGURED"}"#

    private var server: LoopbackAuthServer!
    /// The manager holds its client weakly, so the test owns the strong
    /// reference for the lifetime of the case.
    private var client: JsBaoClient!

    override func setUp() async throws {
        try await super.setUp()
        server = try LoopbackAuthServer()
        server.on("/oauth-config", .ok(#"{"appId":"test-app","emailSignInEnabled":true}"#))
        server.on("/passkey/auth/start", .init(status: 400, json: Self.rpNotConfigured))
        server.on("/passkey/register/start", .init(status: 400, json: Self.rpNotConfigured))
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        client = nil
        try await super.tearDown()
    }

    // MARK: - The configured relying party

    /// The mismatched-host shape from the migration note (DSO-3080-1): an app
    /// whose `webUrl` host is not among its configured relying parties now
    /// gets a typed rejection instead of the server's first-configured-RP
    /// guess — and the manager reports it cleanly rather than hanging.
    func testTheConfiguredRelyingPartyIsSentAndItsRejectionStaysTyped() async throws {
        let manager = try makeManager(passkeyRpId: "app.example.com")

        await manager.signInWithPasskey()

        XCTAssertEqual(startRpId(path: "/passkey/auth/start"), "app.example.com")
        XCTAssertEqual(manager.authFailure?.code, .passkeyRpNotConfigured)
        XCTAssertEqual(manager.authError, "Passkeys are not configured for this app")
        XCTAssertFalse(manager.isAuthenticating)
    }

    // MARK: - The per-call relying party

    func testAPerCallRelyingPartyWinsOverTheConfiguredOne() async throws {
        let manager = try makeManager(passkeyRpId: "app.example.com")

        await manager.signInWithPasskey(rpId: "notes.example.com")

        XCTAssertEqual(startRpId(path: "/passkey/auth/start"), "notes.example.com")
    }

    func testEnrollmentSendsItsRelyingPartyAndPublishesTheRejection() async throws {
        let manager = try makeManager(passkeyRpId: "app.example.com")

        let enrolled = await manager.enrollPasskey(
            deviceName: "Test iPhone", rpId: "notes.example.com"
        )

        XCTAssertFalse(enrolled)
        XCTAssertEqual(startRpId(path: "/passkey/register/start"), "notes.example.com")
        XCTAssertNotNil(manager.authFailure)
        // Enrollment happens after sign-in, so a failed one must not push the
        // login UI anywhere.
        XCTAssertEqual(manager.loginState, .initial)
    }

    // MARK: - Helpers

    private func startRpId(path: String) -> String? {
        server.lastRequestJSON(matching: path)?["rpId"] as? String
    }

    /// A manager attached to a client pointed at the loopback server, built
    /// with the `AuthConfig` `PrimitiveAppState.initialize()` builds.
    private func makeManager(passkeyRpId: String?) throws -> PrimitiveAuthManager {
        let origin = try server.start()
        client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: origin,
            wsUrl: "ws://127.0.0.1:\(server.port)",
            appId: "test-app",
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            auth: AuthConfig(passkeyRpId: passkeyRpId),
            autoNetwork: false
        ))
        let manager = PrimitiveAuthManager(callbackScheme: "primitive-test")
        manager.attach(to: client)
        return manager
    }
}
