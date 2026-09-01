import XCTest
import SwiftUI
@testable import PrimitiveApp
import JsBaoClient

/// Issue #3085 — a waitlisted user gets the SAME story on iOS as on the web.
///
/// The Vue template has a dedicated `waitlisted` login state; the Swift
/// template had none, so an app that told a web visitor "you're on the
/// waitlist" told the same person on iOS that their code was wrong. The
/// manager now lands in `.waitlisted` on `ADDED_TO_WAITLIST`, and
/// `PrimitiveLoginView` renders a waitlist panel for it.
///
/// The panel choice is a pure function of the login state (`panel(for:)`), so
/// which screen a state produces is tested rather than reviewed — a SwiftUI
/// `body` is not inspectable in a unit test, and "renders the waitlist panel"
/// is the assertion that matters.
@MainActor
final class PrimitiveLoginViewWaitlistTests: XCTestCase {

    private static let waitlistBody =
        #"{"error":"This app is invite-only. You've been added to the waitlist.","code":"ADDED_TO_WAITLIST"}"#

    private var server: LoopbackAuthServer!
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

    private func makeManager() throws -> PrimitiveAuthManager {
        let origin = try server.start()
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

    // MARK: - The manager lands in the waitlist state

    func testAWaitlistedEmailRequestEntersTheWaitlistState() async throws {
        server.on("/auth/email/request", .init(status: 403, json: Self.waitlistBody))
        let manager = try makeManager()

        await manager.requestEmailSignIn(email: "nobody@example.test")

        XCTAssertEqual(manager.loginState, .waitlisted(email: "nobody@example.test"))
        XCTAssertEqual(PrimitiveLoginView.panel(for: manager.loginState), .waitlisted)
    }

    /// The server gates a waitlisted address at BOTH ends of the email flow
    /// (`/auth/otp/request` and `/auth/otp/verify`), so verify lands on the
    /// waitlist screen too rather than back on the code field.
    func testAWaitlistedVerifyEntersTheWaitlistState() async throws {
        server.on("/auth/otp/verify", .init(status: 403, json: Self.waitlistBody))
        let manager = try makeManager()

        await manager.verifyOtp(email: "nobody@example.test", code: "123456")

        XCTAssertEqual(manager.loginState, .waitlisted(email: "nobody@example.test"))
    }

    /// "Back to sign in" from the waitlist screen is the ordinary reset.
    func testResetLeavesTheWaitlistState() async throws {
        server.on("/auth/email/request", .init(status: 403, json: Self.waitlistBody))
        let manager = try makeManager()

        await manager.requestEmailSignIn(email: "nobody@example.test")
        manager.reset()

        XCTAssertEqual(manager.loginState, .initial)
        XCTAssertEqual(PrimitiveLoginView.panel(for: manager.loginState), .signIn)
    }

    /// A rejection that is NOT the waitlist keeps the old behavior: the error
    /// panel for a request, the code field for a verify.
    func testOtherRejectionsDoNotEnterTheWaitlistState() async throws {
        server.on(
            "/auth/email/request",
            .init(
                status: 403,
                json: #"{"error":"This app is invite-only.","code":"INVITATION_REQUIRED"}"#
            )
        )
        let manager = try makeManager()

        await manager.requestEmailSignIn(email: "nobody@example.test")

        XCTAssertEqual(manager.loginState, .error("This app is invite-only."))
        XCTAssertEqual(PrimitiveLoginView.panel(for: manager.loginState), .signIn)
    }

    // MARK: - The view

    func testEveryLoginStateMapsToItsPanel() {
        XCTAssertEqual(PrimitiveLoginView.panel(for: .initial), .signIn)
        XCTAssertEqual(PrimitiveLoginView.panel(for: .error("nope")), .signIn)
        XCTAssertEqual(PrimitiveLoginView.panel(for: .sendingEmail), .sendingEmail)
        XCTAssertEqual(
            PrimitiveLoginView.panel(for: .emailSent(email: "a@b.test")),
            .checkEmail(email: "a@b.test")
        )
        XCTAssertEqual(PrimitiveLoginView.panel(for: .verifyingOtp), .signingIn)
        XCTAssertEqual(PrimitiveLoginView.panel(for: .authenticating), .signingIn)
        XCTAssertEqual(PrimitiveLoginView.panel(for: .waitlisted(email: nil)), .waitlisted)
    }

    /// The waitlist panel is the whole story, so the shared red error line —
    /// which would repeat the server's "this app is invite-only" underneath —
    /// stays out of it, exactly as in the Vue template.
    func testTheWaitlistPanelShowsNoErrorLine() {
        XCTAssertFalse(PrimitiveLoginView.showsErrorMessage(in: .waitlisted))
        XCTAssertTrue(PrimitiveLoginView.showsErrorMessage(in: .signIn))
        XCTAssertTrue(PrimitiveLoginView.showsErrorMessage(in: .checkEmail(email: "a@b.test")))
    }

    /// The copy mirrors `PrimitiveLogin.vue`'s waitlisted state, so the same
    /// app says the same thing on both platforms.
    func testTheWaitlistCopyMatchesTheVueTemplate() {
        XCTAssertEqual(PrimitiveLoginView.waitlistTitle, "You're on the waitlist")
        XCTAssertEqual(
            PrimitiveLoginView.waitlistDetail(appName: "Acme"),
            "We've added you to the waitlist for Acme. "
                + "We'll send you an email when your access is approved."
        )
    }

    func testTheViewStillBuildsWithAnAuthManager() {
        _ = PrimitiveLoginView(appName: "Acme", authManager: PrimitiveAuthManager(callbackScheme: "x"))
    }
}
