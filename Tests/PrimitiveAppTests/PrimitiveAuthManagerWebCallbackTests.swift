import XCTest
@testable import PrimitiveApp

/// Issue #2982 — the emailed sign-in link becomes ONE https URL that opens the
/// installed app and still signs in from any browser.
///
/// A custom-scheme target (`<scheme>://auth/magic-link`) is dead in the
/// Simulator, dead on a device without the app, and unclickable in most
/// webmail. An app that also has a web client can send that client's https
/// callback instead: iOS intercepts it as a universal link when the app is
/// installed, and it is an ordinary web sign-in everywhere else. The server
/// sees an ordinary explicit allow-listed target either way.
///
/// The decision is three pure functions so it is tested rather than reviewed:
/// which target (``PrimitiveAuthManager/emailSignInRedirectUri(sendsLink:scheme:webCallback:)``),
/// whether to send one at all (``PrimitiveAuthManager/resolvedSendsLink(override:schemeWasExplicit:webCallbackConfigured:)``),
/// and how the https target is built (``PrimitiveAuthManager/webEmailSignInCallback(appBaseURL:path:)``).
@MainActor
final class PrimitiveAuthManagerWebCallbackTests: XCTestCase {

    // MARK: - Which target the request carries

    func testTheWebCallbackWinsOverTheSchemeTarget() {
        // Both configured: the https URL is the one that works wherever the
        // email is opened, so it is the one that goes out.
        XCTAssertEqual(
            PrimitiveAuthManager.emailSignInRedirectUri(
                sendsLink: true,
                scheme: "myapp-01j8",
                webCallback: URL(string: "https://app.example.com/oauth/callback")
            ),
            "https://app.example.com/oauth/callback"
        )
    }

    func testFallsBackToTheSchemeTargetWithNoWebCounterpart() {
        // A deliberately wired iOS-only app keeps #2969's flow untouched.
        XCTAssertEqual(
            PrimitiveAuthManager.emailSignInRedirectUri(
                sendsLink: true,
                scheme: "myapp-01j8",
                webCallback: nil
            ),
            "myapp-01j8://auth/magic-link"
        )
    }

    func testSendsNoTargetWhenLinkEmailsAreOffEvenWithAWebCounterpart() {
        // The kill switch stays absolute: code-only means no target at all,
        // which is what keeps the allow-list out of the request.
        XCTAssertNil(
            PrimitiveAuthManager.emailSignInRedirectUri(
                sendsLink: false,
                scheme: "myapp-01j8",
                webCallback: URL(string: "https://app.example.com/oauth/callback")
            )
        )
    }

    func testTheTwoArgumentCallShapeStillCompilesAndBehavesIdentically() {
        // Source compatibility (DSO-2982-018): the waiver covers installed
        // binaries, not downstream call sites. `webCallback` defaults to nil,
        // so an existing caller keeps byte-identical behavior.
        XCTAssertEqual(
            PrimitiveAuthManager.emailSignInRedirectUri(sendsLink: true, scheme: "x"),
            "x://auth/magic-link"
        )
        XCTAssertNil(PrimitiveAuthManager.emailSignInRedirectUri(sendsLink: false, scheme: "x"))
    }

    // MARK: - Whether a link is sent at all

    func testTheDefaultIsLinkOnWheneverEitherTargetIsConfigured() {
        // Neither: code-only, the out-of-the-box default that needs no server
        // configuration at all.
        XCTAssertFalse(
            PrimitiveAuthManager.resolvedSendsLink(
                override: nil, schemeWasExplicit: false, webCallbackConfigured: false
            )
        )
        // An explicit scheme is #2969's deliberate wiring.
        XCTAssertTrue(
            PrimitiveAuthManager.resolvedSendsLink(
                override: nil, schemeWasExplicit: true, webCallbackConfigured: false
            )
        )
        // A web counterpart is this issue's: the scaffolded combined app sends
        // its https callback with no app-code change.
        XCTAssertTrue(
            PrimitiveAuthManager.resolvedSendsLink(
                override: nil, schemeWasExplicit: false, webCallbackConfigured: true
            )
        )
        XCTAssertTrue(
            PrimitiveAuthManager.resolvedSendsLink(
                override: nil, schemeWasExplicit: true, webCallbackConfigured: true
            )
        )
    }

    func testAnExplicitOverrideWinsInEveryCombination() {
        for schemeWasExplicit in [true, false] {
            for webCallbackConfigured in [true, false] {
                XCTAssertTrue(
                    PrimitiveAuthManager.resolvedSendsLink(
                        override: true,
                        schemeWasExplicit: schemeWasExplicit,
                        webCallbackConfigured: webCallbackConfigured
                    ),
                    "explicit true must win (scheme: \(schemeWasExplicit), web: \(webCallbackConfigured))"
                )
                XCTAssertFalse(
                    PrimitiveAuthManager.resolvedSendsLink(
                        override: false,
                        schemeWasExplicit: schemeWasExplicit,
                        webCallbackConfigured: webCallbackConfigured
                    ),
                    "explicit false must win (scheme: \(schemeWasExplicit), web: \(webCallbackConfigured))"
                )
            }
        }
    }

    // MARK: - Building the https target

    func testAppendsTheCallbackPathToTheConfiguredOrigin() {
        XCTAssertEqual(
            PrimitiveAuthManager.webEmailSignInCallback(
                appBaseURL: URL(string: "https://app.example.com"),
                path: PrimitiveAuthManager.defaultEmailSignInWebCallbackPath
            ),
            URL(string: "https://app.example.com/oauth/callback")
        )
        // The default path is the web template's own callback route; the
        // apple-app-site-association component matches the same path.
        XCTAssertEqual(
            PrimitiveAuthManager.defaultEmailSignInWebCallbackPath,
            "/oauth/callback"
        )
    }

    func testNormalizesATrailingSlashOnTheBase() {
        XCTAssertEqual(
            PrimitiveAuthManager.webEmailSignInCallback(
                appBaseURL: URL(string: "https://app.example.com/"),
                path: "/oauth/callback"
            ),
            URL(string: "https://app.example.com/oauth/callback")
        )
    }

    func testHonorsACustomCallbackPathWithOrWithoutALeadingSlash() {
        XCTAssertEqual(
            PrimitiveAuthManager.webEmailSignInCallback(
                appBaseURL: URL(string: "https://app.example.com"),
                path: "/auth/finish"
            ),
            URL(string: "https://app.example.com/auth/finish")
        )
        XCTAssertEqual(
            PrimitiveAuthManager.webEmailSignInCallback(
                appBaseURL: URL(string: "https://app.example.com"),
                path: "auth/finish"
            ),
            URL(string: "https://app.example.com/auth/finish")
        )
    }

    func testNoBaseMeansNoWebCallback() {
        // No web counterpart configured — the app is iOS-only, and the
        // scheme path (or code-only) is all there is.
        XCTAssertNil(
            PrimitiveAuthManager.webEmailSignInCallback(appBaseURL: nil, path: "/oauth/callback")
        )
    }

    // MARK: - The manager's own state

    func testAManagerWithAWebCounterpartConfiguredSendsTheHttpsTarget() {
        // The compound delta-3 regression: an explicit-scheme manager used to
        // send a scheme target that 400s once the scheme is un-allow-listed.
        let manager = PrimitiveAuthManager(callbackScheme: "myapp-01j8")
        manager.emailSignInWebCallbackPath = "/oauth/callback"
        let webCallback = PrimitiveAuthManager.webEmailSignInCallback(
            appBaseURL: URL(string: "https://app.example.com"),
            path: manager.emailSignInWebCallbackPath
        )
        XCTAssertEqual(
            PrimitiveAuthManager.emailSignInRedirectUri(
                sendsLink: manager.sendsEmailSignInLink,
                scheme: manager.callbackScheme,
                webCallback: webCallback
            ),
            "https://app.example.com/oauth/callback"
        )
    }

    func testACustomCallbackPathChangesTheTargetTheManagerWouldSend() {
        let manager = PrimitiveAuthManager(callbackScheme: "myapp-01j8")
        manager.emailSignInWebCallbackPath = "/signin/finish"
        XCTAssertEqual(
            PrimitiveAuthManager.webEmailSignInCallback(
                appBaseURL: URL(string: "https://app.example.com"),
                path: manager.emailSignInWebCallbackPath
            ),
            URL(string: "https://app.example.com/signin/finish")
        )
    }

    func testTheKillSwitchStillForcesCodeOnly() {
        let manager = PrimitiveAuthManager(callbackScheme: "myapp-01j8")
        manager.sendsEmailSignInLink = false
        XCTAssertFalse(manager.sendsEmailSignInLink)
        XCTAssertNil(
            PrimitiveAuthManager.emailSignInRedirectUri(
                sendsLink: manager.sendsEmailSignInLink,
                scheme: manager.callbackScheme,
                webCallback: URL(string: "https://app.example.com/oauth/callback")
            )
        )
        manager.sendsEmailSignInLink = true
        XCTAssertTrue(manager.sendsEmailSignInLink)
    }
}
