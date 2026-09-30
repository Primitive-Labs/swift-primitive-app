import XCTest
@testable import PrimitiveApp
import JsBaoClient

/// Issue #3080 — the relying party reaches the wire from `initialize()`, with
/// no app code.
///
/// The composed path is the point: `primitive.json` → `PrimitiveAppConfig` →
/// the `passkeyRpId(for:)` hook → the `AuthConfig` `initialize()` builds the
/// client with → `AuthController`'s default → the `rpId` key in the start POST.
/// `JsBaoClient.options` is private, so the request body is the honest
/// observation point — and it is also the one that would catch the missing
/// `AuthConfig` argument this issue reports.
@MainActor
final class PrimitiveAppStatePasskeyRpIdTests: XCTestCase {

    /// What the server answers a start call with here — the ceremony never
    /// gets as far as a system sheet, and the assertion is on the REQUEST.
    private static let rejection =
        #"{"error":"Passkeys are not configured for this app","code":"PASSKEY_RP_NOT_CONFIGURED"}"#

    private var server: LoopbackAuthServer!

    override func setUp() async throws {
        try await super.setUp()
        // The inspector is a start-once singleton with its own port; keep it
        // out of a test process entirely.
        setenv("PRIMITIVE_DEBUG_INSPECTOR", "0", 1)
        server = try LoopbackAuthServer()
        server.on("/oauth-config", .ok(#"{"appId":"test-app","emailSignInEnabled":true}"#))
        server.on("/passkey/auth/start", .init(status: 400, json: Self.rejection))
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try await super.tearDown()
    }

    // MARK: - Behaviors

    func testTheEnvironmentsWebHostIsSentAsTheRelyingParty() async throws {
        let body = try await startBody(webUrl: "https://notes.example.com")

        XCTAssertEqual(body["rpId"] as? String, "notes.example.com")
    }

    func testAnAppWithNoWebCounterpartSendsNoRelyingParty() async throws {
        let body = try await startBody(webUrl: nil)

        XCTAssertNil(body["rpId"], "expected server-side selection to be unchanged")
    }

    /// A junk `webUrl` (hand-written `primitive.json`) and an IP-literal one
    /// leave the app exactly where an app with no web counterpart is: nothing
    /// named on the wire, and the `localhost` RP a dev app is seeded with
    /// still selected server-side.
    func testAJunkOrIPLiteralWebUrlSendsNoRelyingParty() async throws {
        let junk = try await startBody(webUrl: "notes.example.com")
        XCTAssertNil(junk["rpId"])

        let loopbackIP = try await startBody(webUrl: "http://127.0.0.1:5173")
        XCTAssertNil(loopbackIP["rpId"])
    }

    func testASubclassOverridingTheHookNamesItsOwnRelyingParty() async throws {
        let body = try await startBody(
            webUrl: "https://app.example.com",
            state: { OverriddenRpState(configPath: $0) }
        )

        // The migration remedy for an app whose configured RP is the parent
        // domain: one method, no reimplemented `initialize()`.
        XCTAssertEqual(body["rpId"] as? String, "example.com")
    }

    func testAnOverrideReturningNilRestoresServerSideSelection() async throws {
        let body = try await startBody(
            webUrl: "https://notes.example.com",
            state: { NoRpState(configPath: $0) }
        )

        XCTAssertNil(body["rpId"])
    }

    // MARK: - Helpers

    /// Initializes an app state against a temp `primitive.json` pointing at
    /// the loopback recorder, runs a passkey auth start through the real
    /// client, and returns the body the client sent.
    private func startBody(
        webUrl: String?,
        state makeState: (URL) -> PrimitiveAppState = { TestAppState(configPath: $0) }
    ) async throws -> [String: Any] {
        let origin = try server.port == 0 ? server.start() : "http://127.0.0.1:\(server.port)"
        // Unique per case: `.sqlite()` storage and persisted-JWT state are
        // keyed by appId, so no case can see another's.
        let appId = "rpid-\(UUID().uuidString)"
        let webUrlLine = webUrl.map { ",\n  \"webUrl\": \"\($0)\"" } ?? ""
        let path = try writeConfig(
            """
            {
              "appId": "\(appId)",
              "appName": "Notes",
              "serverUrl": "\(origin)"\(webUrlLine)
            }
            """
        )

        let state = makeState(path)
        await state.initialize()
        let client = try XCTUnwrap(state.client)

        // Parameterless: whatever reaches the wire came from the AuthConfig
        // `initialize()` built. The server answers 400, so this throws —
        // the assertion is on the request.
        _ = try? await client.auth.passkeyAuthStart()
        await state.cleanup()

        return try XCTUnwrap(
            server.lastRequestJSON(matching: "/passkey/auth/start"),
            "no passkey auth start request was recorded"
        )
    }

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

    /// The app-shaped subclass every case uses: it only points the config
    /// loader at the temp file, exactly as a template app points it at its
    /// bundle.
    private class TestAppState: PrimitiveAppState {
        private let configPath: URL
        init(configPath: URL) {
            self.configPath = configPath
            super.init()
        }
        override func configSearchPaths() -> [URL] { [configPath] }
    }

    private final class OverriddenRpState: TestAppState {
        override func passkeyRpId(for config: PrimitiveAppConfig) -> String? { "example.com" }
    }

    private final class NoRpState: TestAppState {
        override func passkeyRpId(for config: PrimitiveAppConfig) -> String? { nil }
    }
}
