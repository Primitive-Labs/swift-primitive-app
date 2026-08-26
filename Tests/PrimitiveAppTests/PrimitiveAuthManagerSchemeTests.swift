import XCTest
@testable import PrimitiveApp

/// Issue #2969 — the callback scheme the manager resolves, and the redirect
/// target it sends with a sign-in email.
///
/// `requestEmailSignIn` used to send `<scheme>://auth/magic-link`
/// unconditionally. The server fail-closed-rejects a supplied target that
/// misses the app's non-empty `emailRedirectUris` allow-list (400
/// `Invalid redirect URI`), and a freshly scaffolded app has allow-listed no
/// scheme — so every email sign-in from a template app failed. Code-only is
/// the default now: no target is sent unless the app opts into link sign-in.
@MainActor
final class PrimitiveAuthManagerSchemeTests: XCTestCase {

    // MARK: - Scheme resolution from CFBundleURLTypes

    func testResolvesTheSchemeRegisteredUnderThePrimitiveAuthMarker() {
        let urlTypes: [[String: Any]] = [
            [
                "CFBundleURLName": PrimitiveAuthManager.urlTypeName,
                "CFBundleURLSchemes": ["myapp-01j8x2c9v3qk7f4hs0d6re5wtn"],
            ]
        ]
        XCTAssertEqual(
            PrimitiveAuthManager.resolveCallbackScheme(urlTypes: urlTypes),
            "myapp-01j8x2c9v3qk7f4hs0d6re5wtn"
        )
    }

    func testTakesTheFirstSchemeOfTheMarkerEntryOnly() {
        let urlTypes: [[String: Any]] = [
            [
                "CFBundleURLName": "GoogleSignIn",
                "CFBundleURLSchemes": ["com.googleusercontent.apps.123"],
            ],
            [
                "CFBundleURLName": PrimitiveAuthManager.urlTypeName,
                "CFBundleURLSchemes": ["myapp-01j8", "myapp-legacy"],
            ],
        ]
        XCTAssertEqual(
            PrimitiveAuthManager.resolveCallbackScheme(urlTypes: urlTypes),
            "myapp-01j8"
        )
    }

    func testFallsBackToPrimitiveappWhenNoMarkerEntryIsRegistered() {
        XCTAssertEqual(PrimitiveAuthManager.resolveCallbackScheme(urlTypes: nil), "primitiveapp")
        XCTAssertEqual(PrimitiveAuthManager.resolveCallbackScheme(urlTypes: []), "primitiveapp")
        // An app that registers only a Google reversed client ID keeps working.
        XCTAssertEqual(
            PrimitiveAuthManager.resolveCallbackScheme(urlTypes: [
                [
                    "CFBundleURLName": "GoogleSignIn",
                    "CFBundleURLSchemes": ["com.googleusercontent.apps.123"],
                ]
            ]),
            "primitiveapp"
        )
    }

    func testFallsBackToPrimitiveappWhenTheMarkerEntryRegistersNoScheme() {
        XCTAssertEqual(
            PrimitiveAuthManager.resolveCallbackScheme(urlTypes: [
                [
                    "CFBundleURLName": PrimitiveAuthManager.urlTypeName,
                    "CFBundleURLSchemes": [String](),
                ]
            ]),
            "primitiveapp"
        )
        XCTAssertEqual(
            PrimitiveAuthManager.resolveCallbackScheme(urlTypes: [
                ["CFBundleURLName": PrimitiveAuthManager.urlTypeName]
            ]),
            "primitiveapp"
        )
    }

    // MARK: - Link opt-in polarity

    func testAManagerWithNoExplicitSchemeSendsNoLinkByDefault() {
        let manager = PrimitiveAuthManager()
        XCTAssertFalse(manager.sendsEmailSignInLink)
    }

    func testAnExplicitCallbackSchemeKeepsLinkEmailsOn() {
        // A deliberately wired app — it passed a scheme and allow-listed it —
        // keeps its link emails across the upgrade with no code change.
        let manager = PrimitiveAuthManager(callbackScheme: "x")
        XCTAssertEqual(manager.callbackScheme, "x")
        XCTAssertTrue(manager.sendsEmailSignInLink)
    }

    func testTheLinkOptInIsSettableBothWays() {
        let optedIn = PrimitiveAuthManager()
        optedIn.sendsEmailSignInLink = true
        XCTAssertTrue(optedIn.sendsEmailSignInLink)

        let forcedCodeOnly = PrimitiveAuthManager(callbackScheme: "x")
        forcedCodeOnly.sendsEmailSignInLink = false
        XCTAssertFalse(forcedCodeOnly.sendsEmailSignInLink)
    }

    // MARK: - The email request's shape

    func testSendsNoRedirectTargetWhenTheLinkOptInIsOff() {
        // Default, and forced code-only with an explicit scheme: both omit the
        // target, which is what makes the email code-only with no allow-list.
        XCTAssertNil(PrimitiveAuthManager.emailSignInRedirectUri(sendsLink: false, scheme: "x"))
        XCTAssertNil(
            PrimitiveAuthManager.emailSignInRedirectUri(
                sendsLink: false,
                scheme: "myapp-01j8x2c9v3qk7f4hs0d6re5wtn"
            )
        )
    }

    func testSendsExactlyTheSchemeMagicLinkTargetWhenOptedIn() {
        XCTAssertEqual(
            PrimitiveAuthManager.emailSignInRedirectUri(sendsLink: true, scheme: "x"),
            "x://auth/magic-link"
        )
    }
}
