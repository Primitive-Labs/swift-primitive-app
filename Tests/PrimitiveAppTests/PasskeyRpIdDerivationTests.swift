import XCTest
@testable import PrimitiveApp

/// Issue #3080 — the passkey relying party the environment implies.
///
/// A native passkey request carries no `Origin` header, so with no explicit
/// rpId the server picks among the app's configured relying parties on its own
/// (#3024). The app already knows the environment's web counterpart — the
/// origin a browser would be served the same app from — and its host is the RP
/// that browser gets. Derivation is a pure static, tested by table, exactly
/// like `linksBaseURL(webUrl:)` whose origin floor it reuses.
final class PasskeyRpIdDerivationTests: XCTestCase {

    func testTheHostOfAWebOriginIsTheRelyingParty() {
        XCTAssertEqual(
            PrimitiveAppState.defaultPasskeyRpId(webUrl: "https://notes.example.com"),
            "notes.example.com"
        )
        // The combined app's out-of-the-box dev shape, and `localhost` is the
        // RP a new app is created with configured.
        XCTAssertEqual(
            PrimitiveAppState.defaultPasskeyRpId(webUrl: "http://localhost:5173"),
            "localhost"
        )
    }

    func testTheRelyingPartyIsNormalizedToOneSpelling() {
        // Case, a spelled-out default port and a trailing slash all name the
        // same origin, so they must all name the same relying party.
        XCTAssertEqual(
            PrimitiveAppState.defaultPasskeyRpId(webUrl: "https://Notes.Example.com:443/"),
            "notes.example.com"
        )
        XCTAssertEqual(
            PrimitiveAppState.defaultPasskeyRpId(webUrl: "  https://notes.example.com  "),
            "notes.example.com"
        )
    }

    func testAnIPLiteralHostDerivesNoRelyingParty() {
        // An IP address is never a valid WebAuthn RP id — no `webcredentials:`
        // entitlement can name one — and the dev shape matters concretely: a
        // `127.0.0.1` webUrl must not shadow the `localhost` RP a new app is
        // seeded with. These keep today's server-side selection.
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "http://127.0.0.1:5173"))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "https://192.0.2.7"))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "https://[2001:db8::1]:8443"))
    }

    func testEverythingTheOriginFloorRejectsDerivesNoRelyingParty() {
        // Same floor as `linksBaseURL`: a hand-written `primitive.json` that
        // is not a web ORIGIN leaves the app exactly as one with no web
        // counterpart — no rpId named, nothing to crash on.
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: nil))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: ""))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "   "))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "notes.example.com"))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "https://notes.example.com/app"))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "https://notes.example.com?a=1"))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "https://notes.example.com#x"))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "https://user:pw@notes.example.com"))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "http://notes.example.com"))
        XCTAssertNil(PrimitiveAppState.defaultPasskeyRpId(webUrl: "ftp://notes.example.com"))
    }
}
