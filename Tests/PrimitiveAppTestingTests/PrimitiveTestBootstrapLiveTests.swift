import XCTest
@testable import PrimitiveApp
@testable import PrimitiveAppTesting
import JsBaoClient

/// Live integration coverage for the OTP bootstrap + end-to-end headless run.
///
/// Follows the JS parallel (`tests/client/js-bao-client-node-otp-bootstrap.test.ts`)
/// verbatim in spirit: provision a public app in the global-admin context with
/// `otpEnabled` and a whitelisted base, then sign a fresh client in via the
/// `+primitivetest` / `"000000"` bypass and drive a real document through it.
///
/// No mocks (repo rule) — this hits the local dev server on :8787. It skips
/// cleanly when no server is reachable rather than failing the suite.
@MainActor
final class PrimitiveTestBootstrapLiveTests: XCTestCase {

    private var appId: String?

    override func setUp() async throws {
        let reachable = await LiveBackend.isReachable()
        try XCTSkipUnless(
            reachable,
            "Dev server not reachable at \(LiveBackend.httpUrl) — start `node debug-server.js`."
        )
    }

    override func tearDown() async throws {
        if let appId { await LiveBackend.deleteApp(appId) }
        appId = nil
    }

    /// A host that registers one headless test which drives the real backend:
    /// it creates a document through the bootstrapped client.
    private final class DocHost: InspectorTestHost {
        let client: JsBaoClient
        init(client: JsBaoClient) { self.client = client }
        var inspectorTests: [InspectorTest] {
            [
                InspectorTest(group: "Bootstrap", name: "creates a document", environment: .headless) { [client] ctx in
                    let result = try await client.documents.create(
                        options: CreateDocumentOptions(title: "PrimitiveAppTesting live doc")
                    )
                    let documentId = result.metadata?.objectValue?["documentId"]?.stringValue ?? ""
                    ctx.log("created document \(documentId)")
                    try ctx.check(!documentId.isEmpty, "documents.create returned no documentId")
                }
            ]
        }
    }

    func test_bootstrap_authenticates_andRunnerDrivesRealBackend() async throws {
        let app = try await LiveBackend.createWhitelistedApp()
        appId = app.appId

        let config = PrimitiveTestConfig(
            appId: app.appId,
            apiUrl: LiveBackend.httpUrl,
            wsUrl: LiveBackend.wsUrl,
            email: app.signInEmail,
            globalAdminAppId: LiveBackend.globalAdminAppId,
            // Local dev server needs the admin context on the WS upgrade.
            wsHeaders: ["X-Global-Admin-App-Id": LiveBackend.globalAdminAppId]
        )

        let client = try await PrimitiveTestAuth.bootstrapClient(config: config)
        defer { Task { await client.destroy() } }

        // Behavior: the bootstrap authenticated a fresh +primitivetest account.
        XCTAssertNotNil(client.userId, "bootstrap should leave the client authenticated")

        // Behavior: the runner executes a registered headless test end to end
        // against the real backend and reports it passed.
        let host = DocHost(client: client)
        let results = await PrimitiveInspectorTestRunner.run(host: host)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .passed, "runner output: \(results[0].output) err: \(results[0].failureMessage ?? "")")
        XCTAssertTrue(results[0].output.contains("created document"))
    }

    func test_bootstrap_nonWhitelistedEmail_throwsClearError_notHang() async throws {
        let app = try await LiveBackend.createWhitelistedApp()
        appId = app.appId

        // An email NOT covered by the whitelist must be rejected by otpVerify.
        let config = PrimitiveTestConfig(
            appId: app.appId,
            apiUrl: LiveBackend.httpUrl,
            wsUrl: LiveBackend.wsUrl,
            email: "not-whitelisted+primitivetest-ci@example.com",
            authTimeout: 10,
            globalAdminAppId: LiveBackend.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": LiveBackend.globalAdminAppId]
        )

        do {
            let client = try await PrimitiveTestAuth.bootstrapClient(config: config)
            await client.destroy()
            XCTFail("bootstrap must throw for a non-whitelisted email")
        } catch let error as PrimitiveTestAuthError {
            guard case .otpVerifyFailed = error else {
                return XCTFail("expected otpVerifyFailed, got \(error)")
            }
        }
    }
}
