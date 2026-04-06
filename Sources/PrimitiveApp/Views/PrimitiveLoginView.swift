import SwiftUI

/// A ready-made login view supporting Google OAuth, magic link, and OTP.
///
/// Usage:
/// ```swift
/// PrimitiveLoginView(appName: "My App")
/// ```
public struct PrimitiveLoginView: View {
    @EnvironmentObject var appState: PrimitiveAppState
    @ObservedObject var authManager: PrimitiveAuthManager
    let appName: String
    let showGoogleOAuth: Bool

    @State private var email = ""
    @State private var otpCode = ""

    public init(appName: String = "Primitive", showGoogleOAuth: Bool = false, authManager: PrimitiveAuthManager) {
        self.appName = appName
        self.showGoogleOAuth = showGoogleOAuth
        self.authManager = authManager
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text(appName)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Sign in to continue")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Auth content based on state
                VStack(spacing: 16) {
                    switch authManager.loginState {
                    case .initial, .error:
                        initialLoginView
                    case .sendingMagicLink:
                        ProgressView("Sending link...")
                    case .magicLinkSent(let sentEmail):
                        magicLinkSentView(email: sentEmail)
                    case .sendingOtp:
                        ProgressView("Sending code...")
                    case .enteringOtp:
                        otpEntryView
                    case .verifyingOtp, .authenticating:
                        ProgressView("Signing in...")
                    }
                }
                .frame(maxWidth: 320)

                // Error message
                if let error = authManager.authError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Initial Login

    private var initialLoginView: some View {
        VStack(spacing: 16) {
            // Email input
            TextField("Email address", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                #endif

            // Primary: OTP (best native experience -- no redirects needed)
            Button {
                Task { await authManager.requestOtp(email: email) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "number")
                    Text("Sign in with Email Code")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty)

            if showGoogleOAuth {
                dividerWithText("or")

                Button {
                    Task { await authManager.startOAuth() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                        Text("Continue with Google")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Magic Link Sent

    private func magicLinkSentView(email: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
            Text("Check your email")
                .font(.headline)
            Text("We sent a sign-in link to **\(email)**")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back to login") {
                authManager.loginState = .initial
            }
            .font(.caption)
            .padding(.top, 8)
        }
    }

    // MARK: - OTP Entry

    private var otpEntryView: some View {
        VStack(spacing: 12) {
            Text("Enter the 6-digit code")
                .font(.headline)
            Text("Sent to **\(email)**")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("000000", text: $otpCode)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.system(.title2, design: .monospaced))
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif

            Button("Verify") {
                Task { await authManager.verifyOtp(email: email, code: otpCode) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(otpCode.count < 6)

            Button("Back to login") {
                authManager.loginState = .initial
                otpCode = ""
            }
            .font(.caption)
        }
    }

    // MARK: - Helpers

    private func dividerWithText(_ text: String) -> some View {
        HStack {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
    }
}
