import XCTest
@testable import PrimitiveApp
import JsBaoClient

/// Live coverage for signing out and signing in as someone else without
/// restarting the process — the sequence `AuthGateView` drives: sign in, the
/// gate calls `connectClient()`, the user signs out from the Profile screen,
/// and a second account signs in on the same `PrimitiveAppState`.
///
/// No mocks (repo rule): a real `primitive.json` pointing at the local dev
/// server, the real `initialize()`, and two `+primitivetest` accounts signed in
/// through `PrimitiveAuthManager.verifyOtp`. Skips when no server is reachable.
@MainActor
final class PrimitiveAppStateAccountSwitchLiveTests: XCTestCase {

    private var appId: String?
    private var state: PrimitiveAppState?
    private var relay: LoopbackRelay?

    override func setUp() async throws {
        let reachable = await LiveBackend.isReachable()
        try XCTSkipUnless(
            reachable,
            "Dev server not reachable at \(LiveBackend.httpUrl) — start `node debug-server.js`."
        )
        setenv("PRIMITIVE_DEBUG_INSPECTOR", "0", 1)
    }

    override func tearDown() async throws {
        if let state { await state.cleanup() }
        state = nil
        relay?.stop()
        relay = nil
        if let appId { await LiveBackend.deleteApp(appId) }
        appId = nil
    }

    func test_signOutThenSignInAsAnotherAccount_showsOnlyTheNewAccount() async throws {
        let app = try await LiveBackend.createWhitelistedApp()
        appId = app.appId
        let emailA = Self.testAccount(app.baseEmail, suffix: "a")
        let emailB = Self.testAccount(app.baseEmail, suffix: "b")

        let state = try await makeInitializedState(appId: app.appId)

        // Account A signs in and the gate connects.
        try await signIn(state, email: emailA)
        XCTAssertNil(state.errorMessage, "A's first sign-in reported an error")
        XCTAssertEqual(state.userEmail, emailA)
        let client = try XCTUnwrap(state.client)
        let created = try await client.documents.create(
            options: CreateDocumentOptions(title: "A's document")
        )
        let docOfA = try XCTUnwrap(created.metadata?.objectValue?["documentId"]?.stringValue)
        await state.fetchDocuments()
        XCTAssertTrue(state.documents.contains { $0.id == docOfA })

        // Sign-out: no trace of A is left for any screen to show.
        await state.authManager.logout()
        XCTAssertEqual(state.userName, "", "A's name outlived the sign-out")
        XCTAssertEqual(state.userEmail, "", "A's email outlived the sign-out")
        XCTAssertNil(state.userAvatarUrl, "A's avatar outlived the sign-out")
        XCTAssertTrue(state.documents.isEmpty, "A's documents outlived the sign-out")
        XCTAssertNil(state.selectedDocId)

        // Account B signs in on the same state, in the same process.
        try await signIn(state, email: emailB)
        XCTAssertNil(state.errorMessage, "B's sign-in after a sign-out reported an error")
        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.userEmail, emailB)
        XCTAssertFalse(state.documents.contains { $0.id == docOfA }, "B's list holds A's document")
    }

    /// A document list A asked for just before signing out answers after the
    /// sign-out. It must not land in the local cache the next account's list
    /// is read from.
    func test_aListRequestInFlightAtSignOut_neverReachesTheNextAccountsList() async throws {
        let app = try await LiveBackend.createWhitelistedApp()
        appId = app.appId
        let emailA = Self.testAccount(app.baseEmail, suffix: "a")
        let emailB = Self.testAccount(app.baseEmail, suffix: "b")
        let (state, relay) = try await makeRelayedState(appId: app.appId)

        try await signIn(state, email: emailA)
        let client = try XCTUnwrap(state.client)
        let created = try await client.documents.create(
            options: CreateDocumentOptions(title: "A's document")
        )
        let docOfA = try XCTUnwrap(created.metadata?.objectValue?["documentId"]?.stringValue)

        // A's list answers from the local cache and asks the server behind
        // it; the relay holds that request until A has signed out.
        relay.holdRequests(containing: "/me/owned-documents")
        await state.fetchDocuments()
        XCTAssertTrue(state.documents.contains { $0.id == docOfA })
        try await waitUntil("A's list request reaches the relay") { relay.heldRequests > 0 }

        await state.authManager.logout()
        relay.releaseHeldRequests()
        // Long enough for a released answer to arrive and be merged.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        try await signIn(state, email: emailB)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.userEmail, emailB)
        XCTAssertFalse(state.documents.contains { $0.id == docOfA }, "B's list holds A's document")
    }

    /// The reported case: the client rebuilds its socket while the connect
    /// the sign-in started is still opening (it does that on its own — an
    /// account switch on an open socket, a receive-limit raise), so that
    /// connect ends unconnected and the client's immediate reconnect gets
    /// through a moment later. That is a connection succeeding within the
    /// connect window: no error, and B's profile and documents load.
    func test_signInAfterSignOut_whenTheSocketIsRebuiltMidConnect_showsNoErrorAndLoadsTheAccount() async throws {
        let app = try await LiveBackend.createWhitelistedApp()
        appId = app.appId
        let emailA = Self.testAccount(app.baseEmail, suffix: "a")
        let emailB = Self.testAccount(app.baseEmail, suffix: "b")
        let (state, relay) = try await makeRelayedState(appId: app.appId)
        let client = try XCTUnwrap(state.client)

        let docOfB = try await seedAccount(state, email: emailB)
        let docOfA = try await seedAccount(state, email: emailA)

        relay.holdUpgrades()
        let connecting = try await signInStartingConnect(state, email: emailB)
        try await waitUntil("B's connect reaches the relay") { relay.heldUpgrades == 1 }
        await client.forceReconnectAsync()
        relay.releaseUpgrades()
        await connecting.value

        XCTAssertNil(state.errorMessage, "a connection that got through on the reconnect reported an error")
        XCTAssertEqual(client.isConnected, true)
        XCTAssertEqual(state.userEmail, emailB)
        XCTAssertTrue(state.documents.contains { $0.id == docOfB }, "B's document is missing from the list")
        XCTAssertFalse(state.documents.contains { $0.id == docOfA }, "B's list holds A's document")
    }

    /// A connection still down when the connect window closes is reported;
    /// once it does connect, the error goes away and the account's profile
    /// and documents load without another sign-in.
    func test_signInWhoseConnectionStaysDown_showsTheError_thenLoadsTheAccountOnceConnected() async throws {
        let app = try await LiveBackend.createWhitelistedApp()
        appId = app.appId
        let emailA = Self.testAccount(app.baseEmail, suffix: "a")
        let (state, relay) = try await makeRelayedState(appId: app.appId)
        let client = try XCTUnwrap(state.client)

        let docOfA = try await seedAccount(state, email: emailA)

        // The sign-in's connect ends, and the reconnect stays held.
        relay.holdUpgrades()
        let connecting = try await signInStartingConnect(state, email: emailA)
        try await waitUntil("A's connect reaches the relay") { relay.heldUpgrades == 1 }
        await client.forceReconnectAsync()
        await connecting.value

        XCTAssertEqual(state.errorMessage, "Connection error: could not connect")
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(state.userEmail, "")

        relay.releaseUpgrades()
        try await waitUntil("A's profile and documents after the late connect", timeout: 30) {
            client.isConnected
                && state.errorMessage == nil
                && state.userEmail == emailA
                && state.documents.contains { $0.id == docOfA }
        }
        XCTAssertEqual(state.connectionStatus, "Connected", "the status still reads as connecting")
        XCTAssertEqual(state.statusColor, .green)
    }

    /// The window bounds the first attempt too: a sign-in whose very first
    /// handshake stalls is reported once the window closes, not when the
    /// handshake finally gives up, and the account loads once it connects.
    func test_signInWhoseFirstHandshakeStalls_showsTheErrorWhenTheWindowCloses() async throws {
        let app = try await LiveBackend.createWhitelistedApp()
        appId = app.appId
        let emailA = Self.testAccount(app.baseEmail, suffix: "a")
        let (state, relay) = try await makeRelayedState(appId: app.appId)
        let client = try XCTUnwrap(state.client)

        let docOfA = try await seedAccount(state, email: emailA)

        state.connectTimeout = 2
        relay.holdUpgrades()
        let connecting = try await signInStartingConnect(state, email: emailA)
        try await waitUntil("A's connect reaches the relay") { relay.heldUpgrades == 1 }
        // Well short of the handshake's own timeout, so only the window can
        // have ended the wait.
        try await waitUntil("the connection error", timeout: 8) {
            state.errorMessage == "Connection error: could not connect"
        }
        await connecting.value
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(state.userEmail, "")

        relay.releaseUpgrades()
        try await waitUntil("A's profile and documents after the late connect", timeout: 30) {
            client.isConnected
                && state.errorMessage == nil
                && state.userEmail == emailA
                && state.documents.contains { $0.id == docOfA }
        }
        XCTAssertEqual(state.connectionStatus, "Connected", "the status still reads as connecting")
        XCTAssertEqual(state.statusColor, .green)
    }

    // MARK: - Helpers

    /// `<base-local>+primitivetest-<suffix>@<domain>`: a distinct test account
    /// under the app's one whitelisted base email.
    private static func testAccount(_ baseEmail: String, suffix: String) -> String {
        let parts = baseEmail.split(separator: "@", maxSplits: 1)
        return "\(parts[0])+primitivetest-\(suffix)@\(parts[1])"
    }

    /// What `AuthGateView` does: verify the code, and once the manager reports
    /// the account signed in, call `connectClient()`.
    private func signIn(_ state: PrimitiveAppState, email: String) async throws {
        await state.authManager.verifyOtp(email: email, code: "000000")
        if let failure = state.authManager.authFailure {
            throw LiveBackend.LiveError.setup("sign-in as \(email) failed: \(failure.message)")
        }
        try await waitUntil("signed in as \(email)") { state.authManager.isAuthenticated }
        await state.connectClient()
    }

    /// A state whose server is reached through a `LoopbackRelay`, so the test
    /// decides when the WebSocket may connect.
    private func makeRelayedState(appId: String) async throws -> (PrimitiveAppState, LoopbackRelay) {
        let relay = try LoopbackRelay(upstream: LiveBackend.httpUrl)
        self.relay = relay
        let origin = try relay.start()
        return (try await makeInitializedState(appId: appId, serverUrl: origin), relay)
    }

    /// Sign in, create one document, sign out: an account with something of
    /// its own for a later sign-in's list to show (or not).
    private func seedAccount(_ state: PrimitiveAppState, email: String) async throws -> String {
        try await signIn(state, email: email)
        XCTAssertNil(state.errorMessage, "seeding \(email) reported an error")
        let client = try XCTUnwrap(state.client)
        let created = try await client.documents.create(
            options: CreateDocumentOptions(title: "\(email)'s document")
        )
        let documentId = try XCTUnwrap(created.metadata?.objectValue?["documentId"]?.stringValue)
        await state.authManager.logout()
        return documentId
    }

    /// `signIn`, but the gate's `connectClient()` is left running, so the
    /// test can act while it connects.
    private func signInStartingConnect(_ state: PrimitiveAppState, email: String) async throws -> Task<Void, Never> {
        await state.authManager.verifyOtp(email: email, code: "000000")
        if let failure = state.authManager.authFailure {
            throw LiveBackend.LiveError.setup("sign-in as \(email) failed: \(failure.message)")
        }
        try await waitUntil("signed in as \(email)") { state.authManager.isAuthenticated }
        return Task { await state.connectClient() }
    }

    private func makeInitializedState(
        appId: String,
        serverUrl: String = LiveBackend.httpUrl
    ) async throws -> PrimitiveAppState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("primitive-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("primitive.json")
        try """
        {
          "appId": "\(appId)",
          "appName": "Account switch",
          "serverUrl": "\(serverUrl)"
        }
        """.write(to: path, atomically: true, encoding: .utf8)

        let state = ConfiguredAppState(configPath: path)
        self.state = state
        await state.initialize()
        let client = try XCTUnwrap(state.client, "initialize() built no client: \(state.errorMessage ?? "")")
        let settled = await client.waitForStorageReady(timeout: 15)
        XCTAssertTrue(settled, "storage did not settle")
        return state
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 10,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw LiveBackend.LiveError.setup("timed out waiting for: \(what)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private final class ConfiguredAppState: PrimitiveAppState {
        private let configPath: URL
        init(configPath: URL) {
            self.configPath = configPath
            super.init()
        }
        override func configSearchPaths() -> [URL] { [configPath] }
    }
}
