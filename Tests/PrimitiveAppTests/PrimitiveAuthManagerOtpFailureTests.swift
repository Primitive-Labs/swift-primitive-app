import XCTest
@testable import PrimitiveApp
import JsBaoClient

/// Issue #3085 — `verifyOtp` said "Invalid code. Please try again." for EVERY
/// failure, so a waitlisted user submitting a perfectly good code was told
/// their code was wrong.
///
/// "Invalid code" belongs to exactly one failure: the server rejecting the
/// submitted code. That is the one failure it reports WITHOUT a machine
/// readable code — `/auth/otp/verify` answers a bare 401 so a brute-forcer
/// learns nothing — while every policy rejection (waitlist, invite-only,
/// domain, rate limit) says what it is.
@MainActor
final class PrimitiveAuthManagerOtpFailureTests: XCTestCase {

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

    // MARK: - Through the manager

    /// The bug from the issue: a waitlisted address verifying a valid code was
    /// told the code was wrong.
    func testAWaitlistedVerifyIsNotReportedAsAnInvalidCode() async throws {
        server.on("/auth/otp/verify", .init(status: 403, json: Self.waitlistBody))
        let manager = try makeManager()

        await manager.verifyOtp(email: "nobody@example.test", code: "123456")

        XCTAssertEqual(manager.authFailure?.code, .addedToWaitlist)
        XCTAssertEqual(
            manager.authError,
            "This app is invite-only. You've been added to the waitlist."
        )
        XCTAssertNotEqual(manager.authError, PrimitiveAuthManager.invalidOtpMessage)
    }

    /// …and the code that IS wrong still reads as wrong.
    func testARejectedCodeStillReportsAnInvalidCode() async throws {
        server.on(
            "/auth/otp/verify",
            .init(status: 401, json: #"{"error":"Invalid or expired code"}"#)
        )
        let manager = try makeManager()

        await manager.verifyOtp(email: "nobody@example.test", code: "123456")

        XCTAssertEqual(manager.authError, PrimitiveAuthManager.invalidOtpMessage)
        XCTAssertNil(manager.authFailure?.code)
        // Back to the code entry screen, so the user can retype it.
        XCTAssertEqual(manager.loginState, .emailSent(email: "nobody@example.test"))
        XCTAssertFalse(manager.isAuthenticating)
    }

    /// `/auth/otp/verify` answers 401 `OTP_MAX_ATTEMPTS` once the attempt
    /// budget is spent — a coded rejection this SDK version has no `AuthCode`
    /// case for. Telling that user to try the code again is wrong twice over:
    /// the server will not accept it, and it has already said what to do.
    func testACodedVerifyRejectionTheSdkDoesNotKnowSaysWhatHappened() async throws {
        server.on(
            "/auth/otp/verify",
            .init(
                status: 401,
                json: #"{"error":"Too many failed attempts. Please request a new code.","code":"OTP_MAX_ATTEMPTS"}"#
            )
        )
        let manager = try makeManager()

        await manager.verifyOtp(email: "nobody@example.test", code: "123456")

        XCTAssertEqual(
            manager.authError,
            "Too many failed attempts. Please request a new code."
        )
        // Unknown to this SDK, so the typed code stays nil — the app falls
        // back to the message, and to `error` for the raw string.
        XCTAssertNil(manager.authFailure?.code)
        let http = try XCTUnwrap(manager.authFailure?.error as? HttpError)
        XCTAssertEqual(http.serverCode, "OTP_MAX_ATTEMPTS")
    }

    // MARK: - The rule itself

    func testOtpVerifyMessagePicksInvalidCodeOnlyForARejectedCode() {
        // A bare 401/400 from the verify endpoint: the code itself.
        XCTAssertEqual(
            PrimitiveAuthManager.otpVerifyMessage(for: HttpError(
                status: 401,
                message: "HTTP 401",
                serverMessage: "Invalid or expired code"
            )),
            PrimitiveAuthManager.invalidOtpMessage
        )
        XCTAssertEqual(
            PrimitiveAuthManager.otpVerifyMessage(for: HttpError(
                status: 400,
                message: "HTTP 400",
                serverMessage: "Invalid code format"
            )),
            PrimitiveAuthManager.invalidOtpMessage
        )
        // A 400/401 that DOES carry a code is not the bare rejection, even
        // when this SDK has no `AuthCode` case for the code — it said what
        // happened, so that is what the user reads.
        XCTAssertEqual(
            PrimitiveAuthManager.otpVerifyMessage(for: HttpError(
                status: 401,
                message: "HTTP 401",
                serverCode: "OTP_MAX_ATTEMPTS",
                serverMessage: "Too many failed attempts. Please request a new code."
            )),
            "Too many failed attempts. Please request a new code."
        )
        XCTAssertEqual(
            PrimitiveAuthManager.otpVerifyMessage(for: HttpError(
                status: 400,
                message: "HTTP 400",
                serverCode: "SOME_NEW_CODE",
                serverMessage: "Something this SDK version has never heard of."
            )),
            "Something this SDK version has never heard of."
        )
        // A policy rejection says what it is.
        XCTAssertEqual(
            PrimitiveAuthManager.otpVerifyMessage(for: HttpError(
                status: 403,
                message: "HTTP 403",
                serverCode: "ADDED_TO_WAITLIST",
                serverMessage: "This app is invite-only. You've been added to the waitlist."
            )),
            "This app is invite-only. You've been added to the waitlist."
        )
        // So does a rate limit, and a 5xx…
        XCTAssertEqual(
            PrimitiveAuthManager.otpVerifyMessage(for: HttpError(
                status: 429,
                message: "HTTP 429",
                serverMessage: "Too many failed OTP verify attempts. Please try again later."
            )),
            "Too many failed OTP verify attempts. Please try again later."
        )
        XCTAssertEqual(
            PrimitiveAuthManager.otpVerifyMessage(for: HttpError(
                status: 500, message: "HTTP 500", serverMessage: "Internal error"
            )),
            "Internal error"
        )
        // …and so does an outage, which never reached the server at all.
        XCTAssertEqual(
            PrimitiveAuthManager.otpVerifyMessage(
                for: JsBaoNetworkError(message: "The Internet connection appears to be offline.")
            ),
            "The Internet connection appears to be offline."
        )
    }
}
