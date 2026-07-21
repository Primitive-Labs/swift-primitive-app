import Foundation
import JsBaoClient

/// Test-account bootstrap for the headless `InspectorTest` runner.
///
/// The Swift analog of the OTP sign-in the JS vitest adapter performs in its
/// `beforeAll` (`client.otpVerify(email, "000000")` in
/// `packages/primitive-app/src/testing/index.ts`). Builds a `JsBaoClient`,
/// signs it in through the `+primitivetest` test bypass, and connects it —
/// with no email delivery and no interactive OAuth — so registered tests can
/// drive a real backend headlessly.
///
/// Usage from a test target (XCTest shown; swift-testing works the same):
///
/// ```swift
/// let config = try PrimitiveTestConfig.fromEnvironment()
/// let client = try await PrimitiveTestAuth.bootstrapClient(config: config)
/// // Wire `client` into your app state / test host, then run:
/// let results = await PrimitiveInspectorTestRunner.run(host: myHost)
/// for r in results where r.status == .failed {
///     XCTFail("[\(r.id)] \(r.failureMessage ?? "failed")\n\(r.output)")
/// }
/// await client.disconnect()
/// ```
public enum PrimitiveTestAuth {

    /// The OTP code the server accepts for whitelisted `+primitivetest` accounts
    /// (`PRIMITIVE_TEST_OTP_CODE` in `src/auth/test-email.ts`). No email is sent.
    public static let testOTPCode = "000000"

    /// Build a `JsBaoClient`, authenticate it via the OTP test bypass, and
    /// connect it to the WebSocket. The returned client is signed in and ready
    /// for registered tests to use.
    ///
    /// Order mirrors the JS adapter: the client is created without auto-network
    /// (no token yet) and any persisted-session restoration is awaited so it
    /// can't later overwrite the OTP token (issue #1780). Once restoration has
    /// settled, any restored local state is purged, then `otpVerify` runs over
    /// HTTP and applies the returned JWT, the user-scoped managers are rebound
    /// to the signed-in user, and finally the WebSocket connects with that token
    /// and we wait for auth to settle. A verify failure (email not on the app's
    /// `testAccountBaseEmails`
    /// whitelist, OTP disabled, invite-only app, …) is rethrown with context
    /// rather than left to surface as a later connection hang.
    ///
    /// **Bootstrap persistence contract (issue #1780).** The returned client is
    /// guaranteed to retain **no** prior test account's session or on-disk
    /// documents/metadata: restored local state is evicted before OTP sign-in.
    /// This matters because `.sqlite` uses one app-wide database and its `meta`
    /// store keys rows by `documentId` alone (not `userId`), so without the
    /// purge a restored account A's on-disk documents would remain visible to
    /// the OTP-signed-in account B. No current test relies on cross-bootstrap
    /// persisted local state; bootstrap means "a fresh client authenticated as
    /// this specific account". Per-user on-disk scoping at the storage layer is
    /// out of scope here and would be filed as its own issue.
    ///
    /// - Parameters:
    ///   - config: connection + test-account settings.
    ///   - clientOptions: optional override of the fully-built
    ///     `JsBaoClientOptions`. Receives the adapter's defaults; return your
    ///     own to customize (e.g. `logLevel`). Return `nil`/omit to accept them.
    /// - Returns: a connected, authenticated `JsBaoClient`.
    public static func bootstrapClient(
        config: PrimitiveTestConfig,
        clientOptions: ((JsBaoClientOptions) -> JsBaoClientOptions)? = nil
    ) async throws -> JsBaoClient {
        let defaults = JsBaoClientOptions(
            apiUrl: config.apiUrl,
            wsUrl: config.wsUrl,
            appId: config.appId,
            offline: false,
            globalAdminAppId: config.globalAdminAppId ?? "global-admin-app",
            wsHeaders: config.wsHeaders,
            logLevel: .warn,
            storageConfig: config.storageConfig,
            // Hold off auto-connecting until the OTP verify has applied a token,
            // so the first WebSocket attempt authenticates instead of racing.
            autoNetwork: false
        )
        let options = clientOptions?(defaults) ?? defaults
        let client = JsBaoClient(options: options)

        // With persistent storage, `JsBaoClient(options:)` kicks off session
        // restoration asynchronously during init. If a valid JWT for a previous
        // test account finishes restoring *after* `otpVerify` applies the new
        // token, the restore overwrites it and the later `waitForAuthReady`
        // returns a client signed in as the wrong user (issue #1780). Wait for
        // the *full* storage-init task to settle before starting the OTP flow —
        // not just token auth-ready. `markAuthReady()` fires partway through
        // `setupStorage`, while the task still snapshots the restored user into
        // `documentManager.userId` and loads that user's metadata; awaiting
        // only auth-ready would let that snapshot race the OTP request.
        // `waitForStorageReady` resolves at the end of the init task regardless
        // of whether a session was found — so memory / fresh-account /
        // no-saved-session configs return promptly and do not stall — and is
        // genuinely bounded by `config.authTimeout` (cancellation-aware), so a
        // stuck startup refresh cannot hang bootstrap past the deadline.
        //
        // On timeout we FAIL FAST rather than proceed. If we started `otpVerify`
        // while restoration was still running, that in-flight restore could
        // finish afterwards and overwrite the OTP token / rebind the restored
        // account's user-scoped state — the exact wrong-user race #1780 exists
        // to prevent (codex cycle-2 P1). Reaching OTP only after a *completed*
        // storage init guarantees restoration ran exactly once and is already
        // settled, so the OTP token can no longer be clobbered.
        let storageReady = await client.waitForStorageReady(timeout: config.authTimeout)
        guard storageReady else {
            await client.destroy()
            throw PrimitiveTestAuthError.storageReadyTimedOut(timeout: config.authTimeout)
        }

        // Purge any restored local state BEFORE the OTP sign-in (issue #1780,
        // sponsor decision). Storage init has settled above, so a restored
        // session (account A) is now fully bound: its JWT lives in
        // `AuthController` and its documents/metadata are on disk. Because
        // `.sqlite` uses one app-wide database whose `meta` and `yjs_docs`
        // stores key rows by `documentId` alone (not by `userId`), account A's
        // on-disk documents would otherwise stay visible to the OTP-signed-in
        // account B — a harness-level rebind can't isolate that.
        // `logout(wipeLocal:)` now purges BOTH on-disk stores at the store
        // level (`clearAllDocumentData`, independent of the in-memory index)
        // and clears the restored JWT, so neither account A's metadata nor its
        // CRDT content survives into the returned client — a reused document ID
        // reopened after OTP can no longer hydrate A's content. When nothing
        // was restored (memory storage, or persistent with no saved session)
        // this is a fast no-op: `DELETE FROM` on the empty stores is instant,
        // and clearing an already-absent token cannot stall. It is
        // best-effort — a purge hiccup must not abort an otherwise-fine
        // bootstrap — and the subsequent `otpVerify` is an interactive login,
        // which clears the non-interactive-auth block `logout` sets.
        try? await client.logout(wipeLocal: true)

        do {
            _ = try await client.otpVerify(email: config.email, code: config.otpCode)
        } catch {
            await client.destroy()
            throw PrimitiveTestAuthError.otpVerifyFailed(email: config.email, underlying: error)
        }

        // The purge above cleared the restored account's session and on-disk
        // documents, but `documentManager` is still bound in memory to whoever
        // init restored (its `userId`), and `otpVerify` updates only
        // `AuthController`. Re-scope the user-owned managers to the
        // just-signed-in user so B's subsequent reads/writes are filed under B,
        // not the restored account's identity (issue #1780). No-op when the
        // signed-in user matches whoever init restored.
        await client.rebindUserScopedStorage()

        do {
            try await client.connect()
            _ = try await client.waitForAuthReady(timeout: config.authTimeout)
        } catch {
            await client.destroy()
            throw PrimitiveTestAuthError.connectFailed(underlying: error)
        }

        return client
    }
}

/// Errors raised while bootstrapping a test-account client.
public enum PrimitiveTestAuthError: Error, CustomStringConvertible {
    /// `otpVerify` was rejected. The most common cause is the email not being a
    /// `+primitivetest` derivative of an address on the app's
    /// `testAccountBaseEmails` whitelist, or OTP being disabled for the app.
    case otpVerifyFailed(email: String, underlying: Error)
    /// The client authenticated but could not connect / reach auth-ready in time.
    case connectFailed(underlying: Error)
    /// Session/storage restoration did not settle within `config.authTimeout`.
    /// Bootstrap fails fast here instead of starting OTP, so a still-running
    /// restore cannot later overwrite the OTP token or rebind the restored
    /// account's local state (issue #1780).
    case storageReadyTimedOut(timeout: TimeInterval)

    public var description: String {
        switch self {
        case let .otpVerifyFailed(email, underlying):
            return "[PrimitiveAppTesting] OTP sign-in failed for \(email). The test bypass requires the app's "
                + "testAccountBaseEmails whitelist to cover this address (a +primitivetest derivative), and "
                + "invite-only/domain/waitlist apps reject provisioning like any signup. Underlying error: \(underlying)"
        case let .connectFailed(underlying):
            return "[PrimitiveAppTesting] Client authenticated but failed to connect / reach auth-ready. "
                + "Underlying error: \(underlying)"
        case let .storageReadyTimedOut(timeout):
            return "[PrimitiveAppTesting] Session/storage restoration did not settle within \(timeout)s; "
                + "bootstrap aborted before OTP to avoid a restore racing the OTP token (issue #1780). "
                + "A slow or stuck startup session refresh is the usual cause."
        }
    }
}
