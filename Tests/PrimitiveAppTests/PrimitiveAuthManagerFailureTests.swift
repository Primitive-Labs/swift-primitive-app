import XCTest
@testable import PrimitiveApp
import JsBaoClient

/// Issue #3085 — a failed sign-in keeps its TYPE.
///
/// `authError` used to be the manager's only failure surface, so an app could
/// not tell "you are on the waitlist" from "your code is wrong" without
/// matching on message text. `authFailure` carries the error the client threw
/// and its `AuthCode` alongside the message, so `ADDED_TO_WAITLIST` /
/// `INVITATION_REQUIRED` / `DOMAIN_NOT_ALLOWED` are branchable.
///
/// The failures are driven through the REAL client path — a loopback HTTP
/// server answers the auth endpoints, so the transport's `HttpError` body
/// parsing and the manager's catch block both run, exactly as they do against
/// a server that returns 403 `ADDED_TO_WAITLIST`.
@MainActor
final class PrimitiveAuthManagerFailureTests: XCTestCase {

    /// The waitlist rejection from the issue, verbatim.
    private static let waitlistBody =
        #"{"error":"This app is invite-only. You've been added to the waitlist.","code":"ADDED_TO_WAITLIST"}"#
    private static let waitlistMessage =
        "This app is invite-only. You've been added to the waitlist."

    private var server: LoopbackAuthServer!
    /// The manager holds its client weakly, so the test owns the strong
    /// reference for the lifetime of the case.
    private var client: JsBaoClient!

    override func setUp() async throws {
        try await super.setUp()
        server = try LoopbackAuthServer()
        server.on("/oauth-config", .ok(#"{"appId":"test-app","emailSignInEnabled":true}"#))
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        client = nil
        try await super.tearDown()
    }

    /// An origin nothing can be listening on: port 1 needs root to bind, so a
    /// request to it is refused at once, on any machine, however busy. Used by
    /// the transport-failure test — stopping the loopback server and reusing
    /// its just-freed ephemeral port is NOT the same guarantee: another
    /// process can claim that port between the stop and the request and answer
    /// it, and the test then fails on someone else's HTTP response.
    private static let closedOrigin = "http://127.0.0.1:1"

    /// A manager attached to a client pointed at the loopback server (or at
    /// `origin`, for a client that must fail to reach anything). Call after
    /// the endpoints under test have been scripted.
    private func makeManager(origin: String? = nil) throws -> PrimitiveAuthManager {
        let origin = try origin ?? server.start()
        client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: origin,
            wsUrl: "ws://127.0.0.1:\(server.port)",
            appId: "test-app",
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))
        let manager = PrimitiveAuthManager(callbackScheme: "primitive-test")
        manager.attach(to: client)
        return manager
    }

    // MARK: - The typed failure is reachable

    func testAWaitlistedEmailSignInPublishesTheTypedCodeAndError() async throws {
        server.on("/auth/email/request", .init(status: 403, json: Self.waitlistBody))
        let manager = try makeManager()

        await manager.requestEmailSignIn(email: "nobody@example.test")

        // The whole point of #3085: no string matching required.
        XCTAssertEqual(manager.authFailure?.code, .addedToWaitlist)
        XCTAssertEqual(manager.authFailure?.message, Self.waitlistMessage)
        let http = try XCTUnwrap(manager.authFailure?.error as? HttpError)
        XCTAssertEqual(http.status, 403)
        XCTAssertEqual(http.serverCode, "ADDED_TO_WAITLIST")
    }

    /// The server's own explanation reaches the user unprefixed — the same
    /// text the Vue template shows — rather than being wrapped in a
    /// client-side sentence about sending email.
    func testTheServersMessageIsPublishedVerbatim() async throws {
        server.on(
            "/auth/email/request",
            .init(
                status: 403,
                json: #"{"error":"This app is invite-only. You need an invitation to sign in.","code":"INVITATION_REQUIRED"}"#
            )
        )
        let manager = try makeManager()

        await manager.requestEmailSignIn(email: "nobody@example.test")

        XCTAssertEqual(manager.authFailure?.code, .invitationRequired)
        XCTAssertEqual(
            manager.authError,
            "This app is invite-only. You need an invitation to sign in."
        )
    }

    // MARK: - Codes an error does or doesn't carry

    func testAuthCodeReadsBothErrorShapesTheClientThrows() {
        XCTAssertEqual(
            PrimitiveAuthManager.authCode(of: HttpError(
                status: 403,
                message: "HTTP 403",
                body: Self.waitlistBody,
                serverCode: "ADDED_TO_WAITLIST",
                serverMessage: Self.waitlistMessage
            )),
            .addedToWaitlist
        )
        XCTAssertEqual(
            PrimitiveAuthManager.authCode(of: AuthError(
                code: .domainNotAllowed, message: "Email domain not allowed"
            )),
            .domainNotAllowed
        )
        // A code the SDK doesn't know, and a failure that isn't an auth
        // rejection at all, both leave the app on the message.
        XCTAssertNil(
            PrimitiveAuthManager.authCode(of: HttpError(
                status: 403, message: "HTTP 403", serverCode: "SOME_NEW_CODE"
            ))
        )
        XCTAssertNil(
            PrimitiveAuthManager.authCode(of: JsBaoNetworkError(message: "offline"))
        )
    }

    // MARK: - Failures with no code, and clearing

    /// An unreachable server is still a failure the app must show — it just
    /// has no `AuthCode`, and keeps the "couldn't send the email" framing
    /// because the server said nothing to show instead.
    func testATransportFailureIsPublishedWithNoCode() async throws {
        // Nothing is listening on `closedOrigin`, so every call this manager
        // makes — the config fetch on attach, then the sign-in — is refused.
        let manager = try makeManager(origin: Self.closedOrigin)

        await manager.requestEmailSignIn(email: "nobody@example.test")

        let failure = try XCTUnwrap(manager.authFailure)
        XCTAssertNil(failure.code)
        XCTAssertNotNil(failure.error)
        XCTAssertEqual(manager.authError, failure.message)
        XCTAssertTrue(
            failure.message.hasPrefix("Failed to send sign-in email: "),
            "unexpected message: \(failure.message)"
        )
    }

    func testResetAndLogoutClearTheTypedFailureWithTheMessage() async throws {
        server.on("/auth/email/request", .init(status: 403, json: Self.waitlistBody))
        let manager = try makeManager()

        await manager.requestEmailSignIn(email: "nobody@example.test")
        XCTAssertNotNil(manager.authFailure)

        manager.reset()
        XCTAssertNil(manager.authFailure)
        XCTAssertNil(manager.authError)

        await manager.requestEmailSignIn(email: "nobody@example.test")
        XCTAssertNotNil(manager.authFailure)

        await manager.logout()
        XCTAssertNil(manager.authFailure)
        XCTAssertNil(manager.authError)
    }

    /// The failure surface a manager can hold with no client attached — a flow
    /// that reported "Client not initialized" — is cleared by `logout()` too.
    /// The client reference is weak, so "no client" is also what a manager that
    /// outlived its client sees, and neither should leave a failure standing
    /// after the logout that was meant to end it.
    func testLogoutClearsTheFailureWithNoClientAttached() async throws {
        let manager = PrimitiveAuthManager(callbackScheme: "primitive-test")

        await manager.startOAuth()
        XCTAssertEqual(manager.authError, "Client not initialized")
        XCTAssertNotNil(manager.authFailure)

        await manager.logout()

        XCTAssertNil(manager.authFailure)
        XCTAssertNil(manager.authError)
        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertEqual(manager.loginState, .initial)
    }
}
