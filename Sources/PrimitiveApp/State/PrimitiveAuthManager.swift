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

    /// The last failed sign-in, with its TYPE intact (#3085).
    ///
    /// `authError` is a rendered sentence; this is what the failure *was*, so
    /// an app can branch on `authFailure?.code == .addedToWaitlist` (or
    /// `.invitationRequired` / `.domainNotAllowed`) instead of matching on
    /// message text. Cleared everywhere `authError` is — at the start of each
    /// flow, on success, on ``reset()`` and on ``logout()`` — so it never
    /// describes a failure the user has already moved past.
    @Published public private(set) var authFailure: AuthFailure?

    /// A failed sign-in, as the manager received it.
    ///
    /// Not `Sendable` (an `Error` existential isn't), which is no restriction
    /// here: `PrimitiveAuthManager` is `@MainActor`, so every reader is
    /// already on the main actor.
    public struct AuthFailure {
        /// The error the client threw, unchanged — an `HttpError` for a server
        /// rejection, `JsBaoNetworkError` for an outage, `AppleSignInError` /
        /// `PasskeyError` for a provider flow. `nil` when the failure arrived
        /// as an `AuthFailedEvent` (a session the client could not keep),
        /// which carries a message only.
        public let error: Error?
        /// The server's `code` field, typed, when the failure carried one.
        /// `nil` for a transport failure, a cancelled sheet, or a code this
        /// SDK version does not know — read `error` for those.
        public let code: AuthCode?
        /// The text published on ``authError`` for this failure. Held here too
        /// so one value describes the failure completely.
        public let message: String
    }

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
        /// The app is invite-only and this address was added to its waitlist
        /// (`ADDED_TO_WAITLIST`) — an outcome, not an error: there is nothing
        /// to retype and nothing to retry (#3085). `email` is the address that
        /// was queued, or nil when the flow that hit the waitlist never named
        /// one (an OAuth or passkey sign-in).
        ///
        /// Matches the Vue template's `waitlisted` login state, so the same
        /// app tells a waitlisted user one story on web and on iOS.
        case waitlisted(email: String?)
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
        /// 6-digit code, and a sign-in link too once the app has a link target
        /// to name: the environment's `webUrl` https callback (#2982) or an
        /// explicit scheme opt-in (#2969). With neither it is code-only.
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

    // MARK: - Callback scheme and link sign-in (#2969, #2982)
    //
    // Two link transports, one decision. A custom scheme (the target
    // ``emailSignInRedirectUri(sendsLink:scheme:webCallback:)`` builds from
    // ``callbackScheme``, and the only place that literal lives) reaches only
    // a device with this app installed; the app's web callback
    // (``emailSignInWebCallbackPath`` on the configured web origin) is
    // a universal link on such a device and a working web sign-in everywhere
    // else, so it wins whenever the app has a web counterpart. Both are
    // ordinary explicit targets to the server: whichever one goes out has to
    // be in the app's `emailRedirectUris`.

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

    /// The path on the app's web counterpart that finishes a sign-in — the
    /// route the Vue template serves at `DEFAULT_OAUTH_CALLBACK_PATH` (#2982).
    ///
    /// Change it only together with the web client's callback route AND the
    /// `applinks` component in the domain's `apple-app-site-association`: the
    /// three name one URL, and a link iOS does not claim is a web page, while
    /// a page the web app does not serve is a dead end.
    public static let defaultEmailSignInWebCallbackPath = "/oauth/callback"

    /// The path appended to the app's web origin to build the emailed sign-in
    /// link's https target. Defaults to ``defaultEmailSignInWebCallbackPath``.
    public var emailSignInWebCallbackPath = defaultEmailSignInWebCallbackPath

    /// Whether a sign-in email should also carry a LINK back into this app.
    ///
    /// **The default follows the app's configuration, and needs no code:**
    ///
    /// - Neither a web counterpart nor an explicit scheme → `false`. The
    ///   request names no redirect target, so the server issues a code-only
    ///   email without consulting the app's `emailRedirectUris` allow-list.
    ///   This is the out-of-the-box shape and it needs no server setup at all.
    /// - A web counterpart configured (the environment's `webUrl` reaching
    ///   `client.links.appBaseURL`) → `true`, and the link is that origin's
    ///   https callback: iOS opens it straight into this app when the app is
    ///   installed, and it is an ordinary web sign-in anywhere else (#2982).
    /// - An explicit `callbackScheme:` and no web counterpart → `true`, with
    ///   the custom-scheme target (#2969's deliberately wired iOS-only app).
    ///
    /// Setting this wins over the default in both directions: `false` forces a
    /// code-only email even with a web counterpart configured, `true` sends a
    /// link via the best target available.
    ///
    /// A supplied target that misses a non-empty allow-list is refused
    /// outright (400 `Invalid redirect URI`) — it does not fall back to a code
    /// — so whichever target goes out has to be in the app's
    /// `[auth].emailRedirectUris`: merge it into the existing array in
    /// `config/app.toml` and run `primitive config push --only app`.
    ///
    /// Worth knowing: a custom-scheme link only opens on a device that has the
    /// app installed (dead in the Simulator, dead cross-device, and many
    /// webmail clients will not render a non-http(s) href at all) — which is
    /// what the https callback fixes. The 6-digit code is the credential that
    /// works regardless of the link's shape.
    public var sendsEmailSignInLink: Bool {
        get {
            Self.resolvedSendsLink(
                override: sendsEmailSignInLinkOverride,
                schemeWasExplicit: schemeWasExplicit,
                webCallbackConfigured: webEmailSignInCallback() != nil
            )
        }
        set { sendsEmailSignInLinkOverride = newValue }
    }

    /// The app's set value, or nil while the default decides. Nil-backed so
    /// that a web counterpart configured AFTER this manager was constructed
    /// (which is the normal order — `attach(to:)` comes later) still flips the
    /// default on, while an explicit set keeps winning.
    private var sendsEmailSignInLinkOverride: Bool?

    /// Whether the app named its own scheme, rather than one being resolved
    /// from the bundle or the shared fallback.
    private let schemeWasExplicit: Bool

    /// Whether a sign-in email carries a link, given what the app configured.
    ///
    /// Pure and static so the polarity is tested rather than reviewed: this is
    /// the switch between "works with no server configuration" and "every
    /// email request 400s because the target is not allow-listed".
    public static func resolvedSendsLink(
        override: Bool?,
        schemeWasExplicit: Bool,
        webCallbackConfigured: Bool
    ) -> Bool {
        override ?? (schemeWasExplicit || webCallbackConfigured)
    }

    /// The https sign-in callback on the app's web counterpart, or nil when
    /// no web origin is configured.
    ///
    /// Pure and static: one place joins the origin and the path, so a base
    /// with a trailing slash cannot produce `//oauth/callback` — a URL that is
    /// neither allow-listed nor claimed by the `applinks` component.
    public static func webEmailSignInCallback(appBaseURL: URL?, path: String) -> URL? {
        guard let appBaseURL else { return nil }
        let base = appBaseURL.absoluteString.hasSuffix("/")
            ? String(appBaseURL.absoluteString.dropLast())
            : appBaseURL.absoluteString
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: base + suffix)
    }

    /// This manager's web callback, from the attached client's configured
    /// ``LinksAPI/appBaseURL`` — the same value that decides which origins an
    /// incoming universal link is trusted from.
    private func webEmailSignInCallback() -> URL? {
        Self.webEmailSignInCallback(
            appBaseURL: client?.links.appBaseURL,
            path: emailSignInWebCallbackPath
        )
    }

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
    /// email (no allow-list involved); the app's web callback is the link when
    /// there is one, because an https URL opens the installed app AND signs in
    /// from any browser; the scheme's callback is the fallback for an app with
    /// no web counterpart. Pure and static so the decision is tested rather
    /// than reviewed — sending a target unconditionally is exactly the bug
    /// #2969 fixed, and sending the scheme when an https target exists is the
    /// 400 #2982 removes.
    ///
    /// `webCallback` defaults to nil so that call sites written against the
    /// two-argument shape compile unchanged, with identical behavior.
    public static func emailSignInRedirectUri(
        sendsLink: Bool,
        scheme: String,
        webCallback: URL? = nil
    ) -> String? {
        guard sendsLink else { return nil }
        if let webCallback { return webCallback.absoluteString }
        return "\(scheme)://auth/magic-link"
    }

    // MARK: - Reading a failure (#3085)

    /// The `AuthCode` an error carries, if any.
    ///
    /// Pure and static so the mapping is tested rather than reviewed, and so
    /// an app can classify an error it caught from `client.auth` directly with
    /// the same rule the manager uses. The client reports a rejected sign-in
    /// two ways — a transport-level `HttpError` whose JSON body carried
    /// `{"code": …}`, and an `AuthError` — and both are read here; anything
    /// else (an outage, a cancelled system sheet, a code newer than this SDK)
    /// has no code, and the caller falls back to the message.
    public static func authCode(of error: Error) -> AuthCode? {
        if let authError = error as? AuthError { return authError.code }
        if let http = error as? HttpError { return http.authCode }
        return nil
    }

    /// The server's own explanation of a failure, when it sent one.
    ///
    /// This is the text that says "you've been added to the waitlist" — the
    /// message the Vue template shows verbatim, and the one worth showing here
    /// instead of a client-side sentence that describes the wrong thing.
    /// `nil` when the failure never reached the server (an outage), or when it
    /// answered with no structured body.
    public static func serverMessage(of error: Error) -> String? {
        if let http = error as? HttpError,
           let message = http.serverMessage, !message.isEmpty {
            return message
        }
        if let authError = error as? AuthError, !authError.message.isEmpty {
            return authError.message
        }
        return nil
    }

    /// Where a failed sign-in leaves the login UI: the waitlist screen when
    /// the server says the address was queued, else the caller's own failure
    /// state (#3085).
    ///
    /// Pure and static so the one state that is NOT an error is decided in one
    /// place, for every flow that can hit it — the server gates a waitlisted
    /// address on the email request, on the code verify, and on an OAuth or
    /// Apple callback alike.
    public static func failureState(
        for error: Error,
        email: String?,
        otherwise: LoginState
    ) -> LoginState {
        authCode(of: error) == .addedToWaitlist ? .waitlisted(email: email) : otherwise
    }

    /// What the user is told when the code they submitted was rejected.
    public static let invalidOtpMessage = "Invalid code. Please try again."

    /// What a failed ``verifyOtp(email:code:)`` should say (#3085).
    ///
    /// "Invalid code" belongs to ONE failure — the server rejecting the
    /// submitted code — and it used to be the answer for all of them, so a
    /// waitlisted user with a perfectly good code was told the code was wrong.
    ///
    /// A rejected code is the one rejection the server describes with no
    /// machine-readable `code` at all: `/auth/otp/verify` answers a bare
    /// 400/401 ("Invalid or expired code") on purpose, because the endpoint is
    /// a brute-force target and an attacker should learn nothing from it.
    /// Every other failure — waitlist, invite-only, domain, rate limit, an
    /// outage, a 5xx — either carries a `code` or is not an HTTP rejection at
    /// all, and says what it is.
    ///
    /// The test is the raw `code` field, not the typed ``AuthCode``: a coded
    /// rejection this SDK version has no case for (`OTP_MAX_ATTEMPTS`, say,
    /// which the server answers 401 with) still said what it is, and telling
    /// that user to retype a code the server will no longer accept is the very
    /// bug this rule exists to fix.
    public static func otpVerifyMessage(for error: Error) -> String {
        if let http = error as? HttpError,
           http.serverCode == nil,
           http.status == 400 || http.status == 401 {
            return invalidOtpMessage
        }
        return serverMessage(of: error) ?? error.localizedDescription
    }

    // MARK: - Private

    /// The ONE place a failed flow updates the manager's failure surface, so
    /// `authError` and ``authFailure`` cannot describe different things.
    ///
    /// Pass `state: nil` for a failure that leaves the login UI where it is
    /// (a passkey management call, say).
    private func publishFailure(_ error: Error, message: String, state: LoginState?) {
        authFailure = AuthFailure(
            error: error,
            code: Self.authCode(of: error),
            message: message
        )
        authError = message
        if let state { loginState = state }
    }

    /// A failure with no error object behind it: the client was never
    /// attached, a callback URL was malformed, or the client reported a lost
    /// session through `AuthFailedEvent`. Keeps the two halves of the surface
    /// in step — a message with a `nil` ``AuthFailure/code``, never a stale
    /// code from an earlier failure.
    private func publishFailure(message: String, state: LoginState? = nil) {
        authFailure = AuthFailure(error: nil, code: nil, message: message)
        authError = message
        if let state { loginState = state }
    }

    /// Clear the failure surface — both halves of it, always together.
    private func clearFailure() {
        authError = nil
        authFailure = nil
    }

    private weak var client: JsBaoClient?
    private var authSuccessSubscription: EventSubscription?
    private var authFailedSubscription: EventSubscription?
    private var authStateSubscription: EventSubscription?

    /// - Parameter callbackScheme: The app's own URL scheme. Omit it and the
    ///   scheme registered under the ``urlTypeName`` URL type is used (falling
    ///   back to `primitiveapp`); pass one and this manager also starts out
    ///   sending link sign-in emails, the way a deliberately wired app did
    ///   before #2969. An app with a web counterpart sends link emails either
    ///   way, via the https callback (#2982).
    public init(callbackScheme: String? = nil) {
        self.callbackScheme =
            callbackScheme
            ?? Self.resolveCallbackScheme(
                urlTypes: Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
                    as? [[String: Any]]
            )
        self.schemeWasExplicit = callbackScheme != nil
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
            self.clearFailure()
            self.handlePostSignIn(cause: event.cause)
        }

        authFailedSubscription = client.observeOnMainActor(AuthFailedEvent.self) { [weak self] event in
            guard let self else { return }
            let msg = event.message ?? "Authentication failed"
            logger.error("Auth failed: \(msg)")
            // No thrown error to keep here — the event carries a message only
            // — but the surface stays whole, so an app never reads a stale
            // `authFailure` next to a fresh `authError`.
            self.publishFailure(message: msg, state: .error(msg))
            self.isAuthenticating = false
            self.isAuthRestoring = false
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
            publishFailure(message: "Client not initialized")
            return
        }

        isAuthenticating = true
        loginState = .authenticating
        clearFailure()

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
            let message = Self.serverMessage(of: error)
                ?? "OAuth failed: \(error.localizedDescription)"
            publishFailure(
                error,
                message: message,
                state: Self.failureState(for: error, email: nil, otherwise: .error(message))
            )
            isAuthenticating = false
        }
    }

    /// Native Google sign-in (#928) via the client's
    /// `signInWithGoogle(...)` — system auth sheet, Google-style custom-scheme
    /// redirect, server-side code exchange. The redirect URI resolves from a
    /// bundled `GoogleService-Info.plist` when `redirectUri` is nil; pass it
    /// explicitly to test without bundling the plist.
    public func signInWithGoogle(redirectUri: String? = nil) async {
        guard let client else {
            publishFailure(message: "Client not initialized")
            return
        }

        isAuthenticating = true
        loginState = .authenticating
        clearFailure()

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
            let message = Self.serverMessage(of: error) ?? error.localizedDescription
            publishFailure(
                error,
                message: message,
                state: Self.failureState(for: error, email: nil, otherwise: .error(message))
            )
            isAuthenticating = false
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
            publishFailure(message: "Client not initialized")
            return
        }

        isAuthenticating = true
        loginState = .authenticating
        clearFailure()

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
            let message = Self.serverMessage(of: error) ?? error.localizedDescription
            publishFailure(
                error,
                message: message,
                state: Self.failureState(for: error, email: nil, otherwise: .error(message))
            )
            isAuthenticating = false
        }
    }

    // MARK: - Passkeys

    /// Sign in with a passkey (#929) via the system sheet (discoverable
    /// credential flow). Requires the app's Associated Domains
    /// (`webcredentials:`) entitlement to cover the server's configured
    /// RP domain.
    ///
    /// `rpId` names the relying party for THIS ceremony (#3080). Leave it nil
    /// — the normal case — and the client uses `AuthConfig.passkeyRpId`, which
    /// ``PrimitiveAppState/initialize()`` sets from the environment's
    /// `webUrl`. Either way the manager's bookkeeping is the same:
    /// `loginState`, `isAuthenticating`, `authFailure` and the on-device
    /// passkey hint.
    public func signInWithPasskey(rpId: String? = nil) async {
        guard let client else {
            publishFailure(message: "Client not initialized")
            return
        }

        isAuthenticating = true
        loginState = .authenticating
        clearFailure()

        do {
            let result = try await client.auth.signInWithPasskey(rpId: rpId)
            logger.info("Passkey sign-in done: userId=\(result.user.userId)")
            recordPasskeyOnDevice()
            // .authSuccess event updates isAuthenticated
        } catch PasskeyError.canceled {
            logger.info("Passkey sign-in cancelled by user")
            isAuthenticating = false
            loginState = .initial
        } catch {
            logger.error("Passkey sign-in error: \(error.localizedDescription)")
            let message = Self.serverMessage(of: error) ?? error.localizedDescription
            publishFailure(
                error,
                message: message,
                state: Self.failureState(for: error, email: nil, otherwise: .error(message))
            )
            isAuthenticating = false
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
    ///
    /// `rpId` names the relying party to register the passkey under (#3080),
    /// exactly as in ``signInWithPasskey(rpId:)``: nil defers to
    /// `AuthConfig.passkeyRpId`, which ``PrimitiveAppState/initialize()`` sets
    /// from the environment's `webUrl`.
    @discardableResult
    public func enrollPasskey(deviceName: String? = nil, rpId: String? = nil) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.auth.registerPasskey(deviceName: deviceName, rpId: rpId)
            logger.info("Passkey enrolled")
            recordPasskeyOnDevice()
            await refreshPasskeys()
            return true
        } catch PasskeyError.canceled {
            logger.info("Passkey enrollment cancelled by user")
            return false
        } catch {
            logger.error("Passkey enrollment error: \(error.localizedDescription)")
            publishFailure(error, message: error.localizedDescription, state: nil)
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
            publishFailure(error, message: error.localizedDescription, state: nil)
            return false
        }
    }

    // MARK: - Email sign-in (#2884)

    /// Request ONE sign-in email carrying a 6-digit code — and, when
    /// ``sendsEmailSignInLink`` is on, a link that opens straight back here.
    ///
    /// With no web counterpart and no scheme opt-in, no redirect target is sent
    /// at all, so the email is code-only and needs no app settings. Configure
    /// the environment's `webUrl` and the link becomes that origin's https
    /// callback — one URL that opens this app when it is installed and signs
    /// in through the browser when it is not (#2982). See
    /// ``sendsEmailSignInLink`` for the full polarity and what each target
    /// requires of the app's allow-list.
    public func requestEmailSignIn(email: String) async {
        guard let client else { return }

        loginState = .sendingEmail
        clearFailure()

        // The client's own `links.appBaseURL` is the single configured origin:
        // the link points back at it, and an incoming universal link is
        // trusted from it. Deriving the target from anything else is how the
        // two drift.
        let webCallback = Self.webEmailSignInCallback(
            appBaseURL: client.links.appBaseURL,
            path: emailSignInWebCallbackPath
        )
        let redirectUri = Self.emailSignInRedirectUri(
            sendsLink: sendsEmailSignInLink,
            scheme: callbackScheme,
            webCallback: webCallback
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
            // The server's own words when it said any — "you've been added to
            // the waitlist" describes the failure; "failed to send sign-in
            // email" describes something that didn't happen. The prefix is
            // kept for failures the server never answered (an outage), where
            // there is nothing better to say.
            let message = Self.serverMessage(of: error)
                ?? "Failed to send sign-in email: \(error.localizedDescription)"
            publishFailure(
                error,
                message: message,
                state: Self.failureState(for: error, email: email, otherwise: .error(message))
            )
        }
    }

    /// Handle a magic link callback URL (from deep link / universal link).
    public func handleMagicLinkCallback(url: URL) async {
        guard let client else { return }

        isAuthenticating = true
        loginState = .authenticating

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "magic_token" })?.value else {
            publishFailure(message: "Invalid magic link URL", state: .error("Invalid magic link URL"))
            isAuthenticating = false
            return
        }

        do {
            let _ = try await client.magicLinkVerify(token: token)
            // Auth success event will update isAuthenticated
        } catch {
            logger.error("Magic link verify failed: \(error.localizedDescription)")
            let message = Self.serverMessage(of: error) ?? "Magic link expired or invalid"
            publishFailure(
                error,
                message: message,
                state: Self.failureState(for: error, email: nil, otherwise: .error(message))
            )
            isAuthenticating = false
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
            let message = Self.otpVerifyMessage(for: error)
            publishFailure(
                error,
                message: message,
                state: Self.failureState(
                    for: error, email: email, otherwise: .emailSent(email: email)
                )
            )
            isAuthenticating = false
        }
    }

    /// Reset the login UI back to the initial screen and clear any pending
    /// auth error. Use this from "Back to login" buttons and similar
    /// affordances rather than mutating `loginState` directly from a View —
    /// it keeps the state-clearing logic in one place and means the View
    /// doesn't have to know about the in-flight `authError` field.
    public func reset() {
        loginState = .initial
        clearFailure()
    }

    // MARK: - Logout

    public func logout() async {
        // Only the remote half needs a client. The manager's own state is
        // cleared either way — it can hold a failure with no client attached
        // ("Client not initialized"), and the reference is weak, so an early
        // return here left `authError` / ``authFailure`` outliving the logout
        // that was meant to end them (#3085).
        if let client {
            do {
                try await client.logout(wipeLocal: true)
            } catch {
                logger.error("Logout error: \(error.localizedDescription)")
            }
        }
        clearSessionScopedPasskeyState()
        isAuthenticated = false
        userId = nil
        clearFailure()
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
