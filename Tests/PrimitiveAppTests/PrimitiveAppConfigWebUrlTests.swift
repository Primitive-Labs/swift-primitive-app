import XCTest
@testable import PrimitiveApp

/// Issue #2982 — the app's web counterpart, carried from the selected
/// Primitive environment into the binary.
///
/// `webUrl` is one value per environment in `.primitive/config.json`, written
/// into `primitive.json` by the template's resolve script. It drives BOTH the
/// outgoing email target (the https callback the sign-in link points at) and
/// the incoming trust (`client.links.appBaseURL`, which is what makes a tapped
/// universal link parse as a magic link instead of `.unknown`) — one value, so
/// the two can never disagree.
///
/// The https callback must live on the same deployment as the environment's
/// backend: a dev build carrying the production callback would send a magic
/// token the production app's server never minted.
final class PrimitiveAppConfigWebUrlTests: XCTestCase {

    private func writeConfig(_ json: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("primitive-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let path = directory.appendingPathComponent("primitive.json")
        try json.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    func testCarriesAWebUrlStringFromPrimitiveJson() throws {
        let path = try writeConfig(
            """
            {
              "primitiveEnv": "prod",
              "appId": "app_123",
              "appName": "Notes",
              "serverUrl": "https://primitiveapi.com",
              "webUrl": "https://notes.example.com"
            }
            """
        )
        guard case .success(let config) = loadPrimitiveAppConfig(searchPaths: [path]) else {
            return XCTFail("expected the config to load")
        }
        XCTAssertEqual(config.appId, "app_123")
        XCTAssertEqual(config.appName, "Notes")
        XCTAssertEqual(config.serverUrl, "https://primitiveapi.com")
        XCTAssertEqual(config.webUrl, "https://notes.example.com")
    }

    func testAnAbsentWebUrlIsNilAndChangesNothingElse() throws {
        let path = try writeConfig(
            """
            {
              "appId": "app_123",
              "serverUrl": "https://primitiveapi.com"
            }
            """
        )
        guard case .success(let config) = loadPrimitiveAppConfig(searchPaths: [path]) else {
            return XCTFail("expected the config to load")
        }
        XCTAssertNil(config.webUrl)
        XCTAssertEqual(config.appId, "app_123")
        // appName still defaults to the app id, as it always did.
        XCTAssertEqual(config.appName, "app_123")
    }

    func testANonStringWebUrlIsReadAsAbsent() throws {
        let path = try writeConfig(
            """
            {
              "appId": "app_123",
              "serverUrl": "https://primitiveapi.com",
              "webUrl": 7
            }
            """
        )
        guard case .success(let config) = loadPrimitiveAppConfig(searchPaths: [path]) else {
            return XCTFail("expected the config to load")
        }
        XCTAssertNil(config.webUrl)
    }

    // MARK: - webUrl → links.appBaseURL

    func testAnOriginBecomesTheLinksBaseURL() {
        XCTAssertEqual(
            PrimitiveAppState.linksBaseURL(webUrl: "https://notes.example.com"),
            URL(string: "https://notes.example.com")
        )
        // Loopback dev origins are the combined app's out-of-the-box shape.
        XCTAssertEqual(
            PrimitiveAppState.linksBaseURL(webUrl: "http://localhost:5173"),
            URL(string: "http://localhost:5173")
        )
    }

    func testJunkIsTreatedAsUnsetRatherThanCrashing() {
        // Everything here leaves the app exactly as it is without a web
        // counterpart: no trusted origin, code-only sign-in emails by default.
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: nil))
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: ""))
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "   "))
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "not a url"))
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "/oauth/callback"))
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "notes.example.com"))
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "ftp://notes.example.com"))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(
            PrimitiveAppState.linksBaseURL(webUrl: "  https://notes.example.com  "),
            URL(string: "https://notes.example.com")
        )
    }

    func testAValueThatIsNotAnOriginIsTreatedAsUnset() {
        // The app's floor: `primitive` rejects these with a message and the
        // resolver drops them, but a hand-written primitive.json passes through
        // neither. Every one of them would otherwise point the emailed sign-in
        // link somewhere it cannot work.

        // A base path is a callback neither the web client (which serves
        // /oauth/callback on its own origin) nor the association file uses.
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "https://notes.example.com/app"))
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "https://notes.example.com/app/"))
        // http off loopback: the server refuses to allow-list it, and the link
        // would carry the magic token in clear.
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "http://notes.example.com"))
        // A query or fragment is not part of an origin, and the callback the
        // manager builds appends a path to it.
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "https://notes.example.com?a=1"))
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "https://notes.example.com#x"))
        // Credentials have no business in a link that goes out by email.
        XCTAssertNil(PrimitiveAppState.linksBaseURL(webUrl: "https://user:pw@notes.example.com"))
    }

    func testAnOriginIsNormalizedToOneSpelling() {
        // Trailing slash and a spelled-out default port mean the same origin,
        // and the trusted origin must not depend on which one was typed.
        XCTAssertEqual(
            PrimitiveAppState.linksBaseURL(webUrl: "https://notes.example.com/"),
            URL(string: "https://notes.example.com")
        )
        XCTAssertEqual(
            PrimitiveAppState.linksBaseURL(webUrl: "https://Notes.Example.com:443"),
            URL(string: "https://notes.example.com")
        )
        XCTAssertEqual(
            PrimitiveAppState.linksBaseURL(webUrl: "http://localhost:5173/"),
            URL(string: "http://localhost:5173")
        )
    }
}
