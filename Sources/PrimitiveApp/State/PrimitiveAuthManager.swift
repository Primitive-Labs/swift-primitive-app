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

    /// Current login UI state
    @Published public var loginState: LoginState = .initial

    public enum LoginState: Equatable {
        case initial
        case sendingMagicLink
        case magicLinkSent(email: String)
        case enteringOtp
        case sendingOtp
        case verifyingOtp
        case authenticating
        case error(String)
    }

    // MARK: - Private

    private weak var client: JsBaoClient?
    private var authSuccessSubscription: EventSubscription?
    private var authFailedSubscription: EventSubscription?
    private var authStateSubscription: EventSubscription?

    /// The custom URL scheme for OAuth/magic link callbacks (e.g. "primitiveapp")
    private let callbackScheme: String

    public init(callbackScheme: String = "primitiveapp") {
        self.callbackScheme = callbackScheme
        super.init()
    }

    /// Attach to a JsBaoClient and listen for auth events.
    public func attach(to client: JsBaoClient) {
        self.client = client

        // Check if already authenticated (e.g. persisted token)
        let state = client.getAuthState()
        if state.authenticated {
            isAuthenticated = true
            userId = client.getUserId()
            logger.info("Already authenticated: userId=\(self.userId ?? "nil")")
        }

        authSuccessSubscription = client.events.on(.authSuccess) { [weak self] (event: AuthSuccessEvent) in
            Task { @MainActor in
                guard let self else { return }
                logger.info("Auth success: cause=\(event.cause ?? "unknown")")
                self.isAuthenticated = true
                self.userId = client.getUserId()
                self.isAuthenticating = false
                self.loginState = .initial
                self.authError = nil
            }
        }

        authFailedSubscription = client.events.on(.authFailed) { [weak self] (event: AuthFailedEvent) in
            Task { @MainActor in
                guard let self else { return }
                let msg = event.message ?? "Authentication failed"
                logger.error("Auth failed: \(msg)")
                self.authError = msg
                self.isAuthenticating = false
                self.loginState = .error(msg)
            }
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

    // MARK: - Magic Link

    /// Request a magic link email.
    public func requestMagicLink(email: String) async {
        guard let client else { return }

        loginState = .sendingMagicLink
        authError = nil

        let redirectUri = "\(callbackScheme)://auth/magic-link"

        do {
            let _ = try await client.magicLinkRequest(email: email, redirectUri: redirectUri)
            logger.info("Magic link sent to \(email)")
            loginState = .magicLinkSent(email: email)
        } catch {
            logger.error("Magic link request failed: \(error.localizedDescription)")
            authError = "Failed to send magic link: \(error.localizedDescription)"
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

    // MARK: - OTP

    /// Request a one-time password sent to email.
    public func requestOtp(email: String) async {
        guard let client else { return }

        loginState = .sendingOtp
        authError = nil

        do {
            let _ = try await client.otpRequest(email: email)
            logger.info("OTP sent to \(email)")
            loginState = .enteringOtp
        } catch {
            logger.error("OTP request failed: \(error.localizedDescription)")
            authError = "Failed to send code: \(error.localizedDescription)"
            loginState = .error(error.localizedDescription)
        }
    }

    /// Verify a one-time password code.
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
            loginState = .enteringOtp
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
        isAuthenticated = false
        userId = nil
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
