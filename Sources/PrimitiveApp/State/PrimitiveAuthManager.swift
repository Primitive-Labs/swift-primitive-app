import Foundation
import SwiftUI
import os
import AuthenticationServices
import JsBaoClient

private let logger = Logger(subsystem: "com.primitivelabs.PrimitiveApp", category: "Auth")

/// Manages authentication flows for Primitive apps.
///
/// Handles Google OAuth (via ASWebAuthenticationSession), magic link, and OTP flows.
/// Listens to JsBaoClient auth events and updates published state accordingly.
@MainActor
public class PrimitiveAuthManager: NSObject, ObservableObject {

    /// Number of digits in the OTP code emailed to users. Surfaced so the
    /// login view can use it both for placeholder text and the verify-button
    /// disabled gate without hardcoding `6` in two places.
    public static let otpLength = 6

    // MARK: - Published State

    @Published public var isAuthenticated = false
    @Published public var userId: String?
    @Published public var authError: String?
    @Published public var isAuthenticating = false

    /// True while the client is attempting to restore a persisted
    /// session on cold start (loading the stored JWT; if it's aged
    /// out, trying a cookie-based refresh). Flips back to false once
    /// the restore attempt resolves, successfully or not.
    ///
    /// Consumers should gate any "you are logged out" UI on this flag
    /// — otherwise the login screen flashes for ~1–2s on cold start
    /// while a refresh is in flight. `AuthGateView` already does this.
    @Published public var isAuthRestoring = false

    /// Current login UI state
    @Published public var loginState: LoginState = .initial

    public enum LoginState: Equatable {
        case initial
        case sendingEmail
        /// ONE "check your email" state (#2884): the same email carries a
        /// 6-digit code and, when a link can be issued, a sign-in link, so
        /// there is nothing here to branch on.
        case emailSent(email: String)
        case verifyingOtp
        case authenticating
        case error(String)
    }

    /// Which sign-in methods the server has configured for this app
    /// (`GET /oauth-config`). Loaded on `attach`; `PrimitiveLoginView`
    /// renders its buttons from this, so apps don't hardcode provider
    /// flags. Nil while loading — the login view shows email-only until
    /// it resolves.
    public struct AuthProviders: Equatable, Sendable {
        public var google: Bool
        public var apple: Bool
        public var passkey: Bool
        /// Email sign-in as ONE method (#2884) — one request, one email, so
        /// there is nothing to enable separately. That email carries a
        /// 6-digit code, and a sign-in link too once the app opts in with
        /// `sendsEmailSignInLink` (#2969); by default it is code-only.
        public var email: Bool

        /// Conservative fallback when the config fetch fails: email only.
        public static let emailOnly = AuthProviders(
            google: false, apple: false, passkey: false, email: true
        )
    }

    @Published public private(set) var availableProviders: AuthProviders?

    /// True when a passkey was registered or used on THIS device for this
    /// app — drives the login screen's passkey-first layout on return
    /// visits. Persisted in UserDefaults per appId.
    @Published public private(set) var hasLocalPasskeyHint = false

    /// One-shot post-sign-in nudge: set after an interactive non-passkey
    /// sign-in when the app supports passkeys, this device has none, and
    /// the user hasn't declined before. `AuthGateView` presents the
    /// enrollment sheet off this; resolve it via `enrollPasskey()` or
    /// `declinePasskeyEnrollment()`.
    @Published public var shouldOfferPasskeyEnrollment = false

    /// Passkeys registered for the signed-in account, for a "manage
    /// passkeys" UI (e.g. `PrimitiveProfileView`). Populated by
    /// `refreshPasskeys()`; kept in sync by `enrollPasskey()` /
    /// `deletePasskey(passkeyId:)`.
    @Published public private(set) var passkeys: [PasskeyInfo] = []

    /// App-level switch for the automatic post-sign-in passkey nudge.
    /// Leave `true` for the standard flow; set `false` before `attach` if
    /// your app wants passkey *sign-in* without the enrollment prompt
    /// (e.g. you offer "Add a passkey" from your own settings screen via
    /// `enrollPasskey()` instead). The server's `passkeyEnabled` app
    /// setting remains the master switch — when it's off, neither the
    /// login button nor the nudge ever appears.
    public var automaticPasskeyEnrollmentPrompt = true

    // MARK: - Callback scheme and link sign-in (#2969)

    /// The `CFBundleURLName` of the app's own URL type, which is where this
    /// manager reads its callback scheme from. `primitive init` stamps an
    /// app-unique scheme into the entry with this name; the template ships it
    /// registered so an emailed link has something to open.
    public static let urlTypeName = "PrimitiveAuth"

    /// The scheme used when the app registers no `PrimitiveAuth` URL type.
    /// Shared by every app that never registered one — which is why iOS link
    /// routing between two of them is ambiguous, and why init stamps.
    public static let fallbackCallbackScheme = "primitiveapp"

    /// The custom URL scheme this app owns, for the OAuth callback
    /// (`<scheme>://oauth/callback`) and the emailed sign-in link. Resolved
    /// once at init: the explicit argument, else the registered
    /// `PrimitiveAuth` scheme, else `primitiveapp`.
    public let callbackScheme: String

    /// Whether a sign-in email should also carry a LINK back into this app.
    ///
    /// **Off by default, and that default works with no server configuration:**
    /// the request names no redirect target, so the server issues a code-only
    /// email without consulting the app's `emailRedirectUris` allow-list. A
    /// supplied target that misses a non-empty allow-list is refused outright
    /// (400 `Invalid redirect URI`) — it does not fall back to a code — so
    /// turning this on takes one server-side step:
    ///
    /// 1. Merge this manager's magic-link callback — the URI
    ///    ``emailSignInRedirectUri(sendsLink:scheme:)`` builds from
    ///    ``callbackScheme`` — into the existing `[auth].emailRedirectUris` in
    ///    `config/app.toml`, then run `primitive config push --only app`.
    /// 2. Set this to `true` before requesting a sign-in email.
    ///
    /// A manager constructed with an explicit `callbackScheme:` starts `true`
    /// — an app that named its own scheme allow-listed it deliberately, and
    /// keeps its link emails. Set it to `false` to force code-only anyway.
    ///
    /// Worth knowing before you turn it on: a custom-scheme link only opens on
    /// a device that has the app installed (dead in the Simulator, dead
    /// cross-device, and many webmail clients will not render a non-http(s)
    /// href at all). The 6-digit code is the credential that always works.
    public var sendsEmailSignInLink: Bool

    /// The app's registered callback scheme, from a `CFBundleURLTypes` array.
    ///
    /// Pure and static so the resolution is unit-testable without a bundle.
    /// Takes the first scheme of the URL type named ``urlTypeName``; anything
    /// missing — no such entry, no schemes in it — resolves the shared
    /// fallback rather than guessing at another app's entry (a Google
    /// reversed client ID, say).
    public static func resolveCallbackScheme(urlTypes: [[String: Any]]?) -> String {
        guard let urlTypes else { return fallbackCallbackScheme }
        for urlType in urlTypes {
            guard urlType["CFBundleURLName"] as? String == urlTypeName else { continue }
            guard let schemes = urlType["CFBundleURLSchemes"] as? [String],
                  let scheme = schemes.first,
                  !scheme.isEmpty else { break }
            return scheme
        }
        return fallbackCallbackScheme
    }

    /// The redirect target a sign-in email request carries, if any.
    ///
    /// The ONE place that decides the request's shape: `nil` is a code-only
    /// email (no allow-list involved), and the scheme's callback is the link.
    /// Pure and static so the decision is tested rather than reviewed —
    /// sending a target unconditionally is exactly the bug this fixes.
    public static func emailSignInRedirectUri(sendsLink: Bool, scheme: String) -> String? {
        sendsLink ? "\(scheme)://auth/magic-link" : nil
    }

    // MARK: - Private

    private weak var client: JsBaoClient?
    private var authSuccessSubscription: EventSubscription?
    private var authFailedSubscription: EventSubscription?
    private var authStateSubscription: EventSubscription?

    /// - Parameter callbackScheme: The app's own URL scheme. Omit it and the
    ///   scheme registered under the ``urlTypeName`` URL type is used (falling
    ///   back to `primitiveapp`); pass one and this manager also starts out
    ///   sending link sign-in emails, the way a deliberately wired app did
    ///   before #2969.
    public init(callbackScheme: String? = nil) {
        self.callbackScheme =
            callbackScheme
            ?? Self.resolveCallbackScheme(
                urlTypes: Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
                    as? [[String: Any]]
            )
        self.sendsEmailSignInLink = callbackScheme != nil
        super.init()
    }

    /// Attach to a JsBaoClient and listen for auth events.
    public func attach(to client: JsBaoClient) {
        self.client = client
        hasLocalPasskeyHint = UserDefaults.standard.bool(forKey: passkeyHintKey)

        // The scheme decides where OAuth and any emailed sign-in link come
        // back to, and every misconfiguration of it is otherwise silent — a
        // dead tap, or a 400 no one sees. Say it once, out loud.
        logger.info(
            "Callback scheme: \(self.callbackScheme, privacy: .public) (link sign-in emails: \(self.sendsEmailSignInLink ? "on" : "off", privacy: .public))"
        )

        // Load the server's configured sign-in methods so the login view
        // can render the right buttons. Email affordances stay on while
        // loading / on failure (AuthProviders.emailOnly fallback).
        Task { @MainActor [weak self] in
            do {
                let config = try await client.auth.getAuthConfig()
                self?.availableProviders = AuthProviders(
                    // The provider enabled AND the `ios` entry usable, from
                    // one property so the button and the flow cannot disagree
                    // (#2891). `hasOAuth` was clientId-only, so a web-only app
                    // rendered a button whose PKCE exchange failed at Google.
                    google: config.googleSignInAvailable,
                    apple: config.hasApple,
                    passkey: config.hasPasskey,
                    email: config.emailSignInEnabled
                )
            } catch {
                logger.warning("Auth config fetch failed; falling back to email-only login: \(error.localizedDescription)")
                self?.availableProviders = .emailOnly
            }
        }

        // Check if already authenticated (e.g. persisted token)
        let state = client.authState
        if state.authenticated {
            isAuthenticated = true
            userId = client.userId
            logger.info("Already authenticated: userId=\(self.userId ?? "nil")")
        } else {
            // The client's async setupStorage() may still be trying to
            // restore a session (load persisted JWT; if aged out, hit
            // /auth/refresh with the cookie). Block any "logged out" UI
            // until that attempt resolves so we don't flash the login
            // screen on cold start.
            //
            // `waitForStorageReady`, not `waitForAuthReady`: the question here
            // is "has restoration finished?", and finishing with nobody signed
            // in is the ordinary answer on a fresh install. Since #2657
            // `waitForAuthReady` throws in exactly that case — it waits for a
            // USER — so using it would hold the UI for the whole timeout on
            // every signed-out cold start. `waitForStorageReady` returns as
            // soon as the init task settles, either way.
            isAuthRestoring = true
            Task { @MainActor [weak self] in
                let settled = await client.waitForStorageReady(timeout: 15)
                if !settled {
                    logger.error("Session restore did not settle within 15s; treating as restore-failed")
                }
                self?.isAuthRestoring = false
            }
        }

        // `observeOnMainActor` already delivers on the main actor, so these
        // handlers touch `@MainActor` state directly.
        authSuccessSubscription = client.observeOnMainActor(AuthSuccessEvent.self) { [weak self] event in
            guard let self else { return }
            logger.info("Auth success: cause=\(event.cause ?? "unknown")")
            let newUserId = client.userId
            if self.userId != nil && self.userId != newUserId {
                self.clearSessionScopedPasskeyState()
            }
            self.isAuthenticated = true
            self.userId = newUserId
            self.isAuthenticating = false
            self.isAuthRestoring = false
            self.loginState = .initial
            self.authError = nil
            self.handlePostSignIn(cause: event.cause)
        }

        authFailedSubscription = client.observeOnMainActor(AuthFailedEvent.self) { [weak self] event in
            guard let self else { return }
            let msg = event.message ?? "Authentication failed"
            logger.error("Auth failed: \(msg)")
            self.authError = msg
            self.isAuthenticating = false
            self.isAuthRestoring = false
            self.loginState = .error(msg)
            self.clearSessionScopedPasskeyState()
        }
    }

    // MARK: - Google OAuth

    /// Start Google OAuth flow using ASWebAuthenticationSession.
    ///
    /// Opens a system browser sheet, handles the redirect callback, and exchanges
    /// the authorization code for a token via the JsBaoClient.
    public func startOAuth() async {
        guard let client else {
            authError = "Client not initialized"
            return
        }

        isAuthenticating = true
        loginState = .authenticating
        authError = nil

        let redirectUri = "\(callbackScheme)://oauth/callback"

        do {
            let authUrl = try await client.startOAuthFlow(redirectUri: redirectUri)
            logger.info("Opening OAuth URL: \(authUrl.absoluteString.prefix(80))...")

            let callbackUrl = try await performWebAuth(url: authUrl)
            logger.info("OAuth callback received")

            // Extract code and state from callback URL
            guard let components = URLComponents(url: callbackUrl, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  let state = components.queryItems?.first(where: { $0.name == "state" })?.value else {
                throw AuthFlowError.missingCallbackParams
            }

            try await client.handleOAuthCallback(code: code, state: state)
            // Auth success event will update isAuthenticated
        } catch AuthFlowError.cancelled {
            logger.info("OAuth flow cancelled by user")
            isAuthenticating = false
            loginState = .initial
        } catch {
            logger.error("OAuth error: \(error.localizedDescription)")
            authError = "OAuth failed: \(error.localizedDescription)"
            isAuthenticating = false
            loginState = .error(error.localizedDescription)
        }
    }

    /// Native Google sign-in (#928) via the client's
    /// `signInWithGoogle(...)` — system auth sheet, Google-style custom-scheme
    /// redirect, server-side code exchange. The redirect URI resolves from a
    /// bundled `GoogleService-Info.plist` when `redirectUri` is nil; pass it
    /// explicitly to test without bundling the plist.
    public func signInWithGoogle(redirectUri: String? = nil) async {
        guard let client else {
            authError = "Client not initialized"
            return
        }

        isAuthenticating = true
        loginState = .authenticating
        authError = nil

        do {
            let result = try await client.signInWithGoogle(redirectUri: redirectUri)
            logger.info("Google sign-in done: userId=\(result.userId ?? "nil") isNewUser=\(result.isNewUser)")
            // .authSuccess event updates isAuthenticated
        } catch OAuthSignInError.cancelled {
            logger.info("Google sign-in cancelled by user")
            isAuthenticating = false
            loginState = .initial
        } catch {
            logger.error("Google sign-in error: \(error.localizedDescription)")
            authError = error.localizedDescription
            isAuthenticating = false
            loginState = .error(error.localizedDescription)
        }
    }

    // MARK: - Sign in with Apple

    /// Native Sign in with Apple (#409 port) via the client's
    /// `signInWithApple()` — system Apple ID sheet, identity-token exchange
    /// against `POST /auth/apple/callback`. Requires the app's
    /// "Sign in with Apple" entitlement and the server's `appleAudiences`
    /// to include this app's bundle id.
    public func signInWithApple() async {
        guard let client else {
            authError = "Client not initialized"
            return
        }

        isAuthenticating = true
        loginState = .authenticating
        authError = nil

        do {
            let result = try await client.signInWithApple()
            logger.info("Apple sign-in done: userId=\(result.userId ?? "nil") isNewUser=\(result.isNewUser)")
            // .authSuccess event updates isAuthenticated
        } catch AppleSignInError.cancelled {
            logger.info("Apple sign-in cancelled by user")
            isAuthenticating = false
            loginState = .initial
        } catch {
            logger.error("Apple sign-in error: \(error.localizedDescription)")
            authError = error.localizedDescription
            isAuthenticating = false
            loginState = .error(error.localizedDescription)
        }
    }

    // MARK: - Passkeys

    /// Sign in with a passkey (#929) via the system sheet (discoverable
    /// credential flow). Requires the app's Associated Domains
    /// (`webcredentials:`) entitlement to cover the server's configured
    /// RP domain.
    public func signInWithPasskey() async {
        guard let client else {
            authError = "Client not initialized"
            return
        }

        isAuthenticating = true
        loginState = .authenticating
        authError = nil

        do {
            let result = try await client.auth.signInWithPasskey()
            logger.info("Passkey sign-in done: userId=\(result.user.userId)")
            recordPasskeyOnDevice()
            // .authSuccess event updates isAuthenticated
        } catch PasskeyError.canceled {
            logger.info("Passkey sign-in cancelled by user")
            isAuthenticating = false
            loginState = .initial
        } catch {
            logger.error("Passkey sign-in error: \(error.localizedDescription)")
            authError = error.localizedDescription
            isAuthenticating = false
            loginState = .error(error.localizedDescription)
        }
    }

    // MARK: - Passkey enrollment (post-sign-in nudge)

    private var passkeyHintKey: String {
        "primitive.passkey.onDevice.\(client?.appId ?? "default")"
    }
    private var passkeyDeclinedKey: String {
        "primitive.passkey.promptDeclined.\(client?.appId ?? "default")"
    }

    /// Sign-in causes that should trigger the one-time "add a passkey?"
    /// nudge: a human just authenticated interactively with something
    /// slower than a passkey. Session restores/refreshes don't count, and
    /// neither does a passkey sign-in itself.
    ///
    /// The strings are the client's cause vocabulary, which #2657 aligned with
    /// the JS client: `oauthCallback` / `magicLinkVerify` / `otpVerify` /
    /// `passkeyAuth`, plus the Swift-only `apple`. (The old set listed
    /// `"oauth"`, which the client never emitted — a Google sign-in was
    /// `"google"` — so the nudge never fired for Google until now.)
    private static let enrollmentNudgeCauses: Set<String> = [
        "oauthCallback", "apple", "otpVerify", "magicLinkVerify",
    ]

    private func handlePostSignIn(cause: String?) {
        guard let cause else { return }
        if cause == "passkeyAuth" {
            recordPasskeyOnDevice()
            return
        }
        guard automaticPasskeyEnrollmentPrompt,
              Self.enrollmentNudgeCauses.contains(cause),
              availableProviders?.passkey == true,
              !hasLocalPasskeyHint,
              !UserDefaults.standard.bool(forKey: passkeyDeclinedKey) else {
            return
        }
        shouldOfferPasskeyEnrollment = true
    }

    private func recordPasskeyOnDevice() {
        hasLocalPasskeyHint = true
        UserDefaults.standard.set(true, forKey: passkeyHintKey)
        shouldOfferPasskeyEnrollment = false
    }

    private func clearSessionScopedPasskeyState() {
        passkeys = []
        shouldOfferPasskeyEnrollment = false
    }

    /// Register a passkey for the signed-in user (the enrollment sheet's
    /// "Add Passkey" action; also usable from a profile/settings screen).
    /// Returns true on success.
    @discardableResult
    public func enrollPasskey(deviceName: String? = nil) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.auth.registerPasskey(deviceName: deviceName)
            logger.info("Passkey enrolled")
            recordPasskeyOnDevice()
            await refreshPasskeys()
            return true
        } catch PasskeyError.canceled {
            logger.info("Passkey enrollment cancelled by user")
            return false
        } catch {
            logger.error("Passkey enrollment error: \(error.localizedDescription)")
            authError = error.localizedDescription
            return false
        }
    }

    /// "Not now" on the enrollment nudge — never auto-prompt again on this
    /// device (the user can still add a passkey from app UI).
    public func declinePasskeyEnrollment() {
        UserDefaults.standard.set(true, forKey: passkeyDeclinedKey)
        shouldOfferPasskeyEnrollment = false
    }

    /// Load the signed-in account's registered passkeys into `passkeys`.
    /// Errors are swallowed (the common one is "passkeys not configured for
    /// this app", which a manage-passkeys screen should treat as "none"
    /// rather than surface as an error). Safe to call on view appear.
    public func refreshPasskeys() async {
        guard let client else { return }
        do {
            passkeys = try await client.auth.passkeyList().passkeys
        } catch {
            logger.info("refreshPasskeys: \(error.localizedDescription)")
        }
    }

    /// Delete one registered passkey and refresh the list. Returns true on
    /// success.
    @discardableResult
    public func deletePasskey(passkeyId: String) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.auth.passkeyDelete(passkeyId: passkeyId)
            await refreshPasskeys()
            return true
        } catch {
            logger.error("deletePasskey error: \(error.localizedDescription)")
            authError = error.localizedDescription
            return false
        }
    }

    // MARK: - Email sign-in (#2884)

    /// Request ONE sign-in email carrying a 6-digit code — and, when
    /// ``sendsEmailSignInLink`` is on, a link that opens straight back here.
    ///
    /// By default no redirect target is sent at all, so the email is code-only
    /// and needs no app settings. See ``sendsEmailSignInLink`` for the opt-in
    /// and what it requires of the app's allow-list.
    public func requestEmailSignIn(email: String) async {
        guard let client else { return }

        loginState = .sendingEmail
        authError = nil

        let redirectUri = Self.emailSignInRedirectUri(
            sendsLink: sendsEmailSignInLink,
            scheme: callbackScheme
        )

        do {
            let _ = try await client.auth.emailSignInRequest(
                email: email,
                redirectUri: redirectUri
            )
            logger.info("Sign-in email sent to \(email)")
            loginState = .emailSent(email: email)
        } catch {
            logger.error("Email sign-in request failed: \(error.localizedDescription)")
            authError = "Failed to send sign-in email: \(error.localizedDescription)"
            loginState = .error(error.localizedDescription)
        }
    }

    /// Handle a magic link callback URL (from deep link / universal link).
    public func handleMagicLinkCallback(url: URL) async {
        guard let client else { return }

        isAuthenticating = true
        loginState = .authenticating

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "magic_token" })?.value else {
            authError = "Invalid magic link URL"
            loginState = .error("Invalid magic link URL")
            isAuthenticating = false
            return
        }

        do {
            let _ = try await client.magicLinkVerify(token: token)
            // Auth success event will update isAuthenticated
        } catch {
            logger.error("Magic link verify failed: \(error.localizedDescription)")
            authError = "Magic link expired or invalid"
            isAuthenticating = false
            loginState = .error("Magic link expired or invalid")
        }
    }

    // MARK: - Finishing with the code

    /// Verify the 6-digit code from the sign-in email.
    public func verifyOtp(email: String, code: String) async {
        guard let client else { return }

        loginState = .verifyingOtp
        isAuthenticating = true

        do {
            let _ = try await client.otpVerify(email: email, code: code)
            // Auth success event will update isAuthenticated
        } catch {
            logger.error("OTP verify failed: \(error.localizedDescription)")
            authError = "Invalid code. Please try again."
            isAuthenticating = false
            loginState = .emailSent(email: email)
        }
    }

    /// Reset the login UI back to the initial screen and clear any pending
    /// auth error. Use this from "Back to login" buttons and similar
    /// affordances rather than mutating `loginState` directly from a View —
    /// it keeps the state-clearing logic in one place and means the View
    /// doesn't have to know about the in-flight `authError` field.
    public func reset() {
        loginState = .initial
        authError = nil
    }

    // MARK: - Logout

    public func logout() async {
        guard let client else { return }
        do {
            try await client.logout(wipeLocal: true)
        } catch {
            logger.error("Logout error: \(error.localizedDescription)")
        }
        clearSessionScopedPasskeyState()
        isAuthenticated = false
        userId = nil
        authError = nil
        loginState = .initial
    }

    // MARK: - ASWebAuthenticationSession

    private func performWebAuth(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackUrl, error in
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(throwing: AuthFlowError.cancelled)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if let callbackUrl {
                    continuation.resume(returning: callbackUrl)
                } else {
                    continuation.resume(throwing: AuthFlowError.missingCallbackParams)
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            #if os(macOS)
            session.presentationContextProvider = self
            #else
            session.presentationContextProvider = self
            #endif
            session.start()
        }
    }

    // MARK: - Cleanup

    public func detach() {
        authSuccessSubscription?.cancel()
        authFailedSubscription?.cancel()
        authStateSubscription?.cancel()
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension PrimitiveAuthManager: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
        #endif
    }
}

// MARK: - Errors

public enum AuthFlowError: Error, LocalizedError {
    case cancelled
    case missingCallbackParams
    case notInitialized

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Authentication was cancelled"
        case .missingCallbackParams: return "Missing parameters in auth callback"
        case .notInitialized: return "Auth manager not initialized"
        }
    }
}
