import XCTest
@testable import PrimitiveApp
import JsBaoClient

/// Vehicle smoke test: nothing in this package drove `initialize()` before,
/// so before any rpId behavior rides on it, prove the composition runs
/// hermetically under `swift test` — temp `primitive.json`, real client
/// construction, loopback server, no inspector, no dev server.
@MainActor
final class PrimitiveAppStateInitializeSmokeTests: XCTestCase {

    private var server: LoopbackAuthServer!

    override func setUp() async throws {
        try await super.setUp()
        setenv("PRIMITIVE_DEBUG_INSPECTOR", "0", 1)
        server = try LoopbackAuthServer()
        server.on("/oauth-config", .ok(#"{"appId":"test-app","emailSignInEnabled":true}"#))
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try await super.tearDown()
    }

    func testInitializeBuildsAClientFromATempPrimitiveJson() async throws {
        let origin = try server.start()
        let appId = "smoke-\(UUID().uuidString)"
        let path = try writeConfig(
            """
            {
              "appId": "\(appId)",
              "appName": "Smoke",
              "serverUrl": "\(origin)",
              "webUrl": "https://notes.example.com"
            }
            """
        )
        let state = TestAppState(configPath: path)

        await state.initialize()

        XCTAssertTrue(state.isInitialized)
        XCTAssertNotNil(state.client)
        XCTAssertEqual(state.appConfig?.appId, appId)
        await state.cleanup()
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

    private final class TestAppState: PrimitiveAppState {
        private let configPath: URL
        init(configPath: URL) {
            self.configPath = configPath
            super.init()
        }
        override func configSearchPaths() -> [URL] { [configPath] }
    }
}
