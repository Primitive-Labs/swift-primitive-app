import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A ready-made login view supporting Google OAuth, magic link, and OTP.
///
/// Usage:
/// ```swift
/// PrimitiveLoginView(appName: "My App")
/// ```
public struct PrimitiveLoginView: View {
    // `appState` is intentionally NOT pulled from `@EnvironmentObject` here.
    // SwiftUI's environment lookup is exact-runtime-type; a subclass of
    // `PrimitiveAppState` injected upstream would not satisfy a
    // `@EnvironmentObject var appState: PrimitiveAppState` declaration and
    // would trap on first access. This view only needs the auth manager,
    // which is passed in explicitly.
    @ObservedObject var authManager: PrimitiveAuthManager
    let appName: String

    @State private var email = ""
    @State private var otpCode = ""

    public init(
        appName: String = "Primitive",
        authManager: PrimitiveAuthManager
    ) {
        self.appName = appName
        self.authManager = authManager
    }

    /// Which buttons to render — straight from the server's auth config
    /// (loaded by `PrimitiveAuthManager.attach`). Email-only until it
    /// resolves, so the form is usable immediately.
    private var providers: PrimitiveAuthManager.AuthProviders {
        authManager.availableProviders ?? .emailOnly
    }

    /// Passkey-first on return visits: a passkey was registered or used on
    /// this device before, so lead with it (the standard iOS pattern).
    private var leadWithPasskey: Bool {
        providers.passkey && authManager.hasLocalPasskeyHint
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
                    case .sendingEmail:
                        ProgressView("Sending sign-in email...")
                    case .emailSent(let sentEmail):
                        emailSentView(email: sentEmail)
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
        // Tap anywhere outside the text fields to clear focus.
        // `.contentShape` makes the Spacer regions hit-testable; without it
        // taps in the empty space above/below the form do nothing.
        .contentShape(Rectangle())
        .onTapGesture {
            dismissKeyboard()
        }
        // ESC key on macOS clears focus from the active text field. The
        // modifier is *unavailable* on iOS (not just inert), so guard it.
        #if os(macOS)
        .onExitCommand { dismissKeyboard() }
        #endif
    }

    /// Resigns first responder on whichever platform we're running on.
    /// iOS: route resignFirstResponder through UIApplication so it walks the
    /// responder chain. macOS: tell the key window to drop its first
    /// responder, which clears focus from any NSTextField hosted by SwiftUI.
    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #elseif canImport(AppKit)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }

    // MARK: - Initial Login

    /// Standard iOS sign-in layout, driven by the server's auth config:
    ///
    /// - Return visit (a passkey lives on this device): passkey first,
    ///   prominent, with the other providers below the divider.
    /// - First visit: Apple, then Google, then email — with a small
    ///   passkey link at the bottom for users who registered one on
    ///   another device.
    private var initialLoginView: some View {
        VStack(spacing: 16) {
            if leadWithPasskey {
                Button {
                    Task { await authManager.signInWithPasskey() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                        Text("Sign in with Passkey")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                dividerWithText("or")
            }

            if providers.apple {
                Button {
                    Task { await authManager.signInWithApple() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "applelogo")
                        Text("Sign in with Apple")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            if providers.google {
                // Native #928 flow (system sheet + plist-derived redirect).
                // The pre-#928 server-redirect flow remains available as
                // `authManager.startOAuth()` for apps that registered a
                // custom-scheme redirect with the server.
                Button {
                    Task { await authManager.signInWithGoogle() }
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

            if providers.email {
                if providers.apple || providers.google {
                    dividerWithText("or")
                }

                TextField("Email address", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    // Stable identifier for UI automation. The idb smoke
                    // scenario (`scripts/smoke-test.sh ui_signin`) locates
                    // this field by identifier, not by placeholder text, so
                    // copy changes don't break it. See the DevTools guide.
                    .accessibilityIdentifier("primitive.login.emailField")
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    #endif

                // ONE email button (#2884). The email that arrives carries a
                // code — and a link too once the app opts in with
                // `sendsEmailSignInLink` (#2969) — so there is no method to
                // pick here.
                emailProminence(
                    Button {
                        Task { await authManager.requestEmailSignIn(email: email) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope")
                            Text("Sign in with Email")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .disabled(email.isEmpty)
                    .accessibilityIdentifier("primitive.login.emailSubmit")
                )
            }

            // Passkey exists server-side but (as far as this device knows)
            // not locally: keep it reachable without leading with it —
            // e.g. a passkey registered on the user's other device.
            if providers.passkey && !leadWithPasskey {
                Button("Sign in with a Passkey") {
                    Task { await authManager.signInWithPasskey() }
                }
                .font(.caption)
            }
        }
    }

    /// `.bordered` vs `.borderedProminent` are distinct opaque types, so a
    /// ternary can't pick between them — branch in a ViewBuilder instead.
    @ViewBuilder
    private func emailProminence<V: View>(_ button: V) -> some View {
        if leadWithPasskey {
            button.buttonStyle(.bordered)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Email Sent (one email: the code, plus a link when opted in)

    private func emailSentView(email sentEmail: String) -> some View {
        let otpLength = PrimitiveAuthManager.otpLength
        return VStack(spacing: 12) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
            Text("Check your email")
                .font(.headline)
            Text("We sent a sign-in email to **\(sentEmail)**")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Code first, link conditionally: link issuance is fail-closed on
            // the server (no allow-listed redirect target, no link), and the
            // request's `{ success: true }` does not say which email went out.
            // Promising a link the app cannot guarantee makes the supported
            // code-only fallback look broken.
            Text("Enter the \(otpLength)-digit code. If that email also has a sign-in link, opening it works too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField(String(repeating: "0", count: otpLength), text: $otpCode)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.system(.title2, design: .monospaced))
                .accessibilityIdentifier("primitive.login.otpField")
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif

            Button("Verify") {
                Task { await authManager.verifyOtp(email: email, code: otpCode) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(otpCode.count < otpLength)
            .accessibilityIdentifier("primitive.login.otpVerify")

            Button("Back to login") {
                authManager.reset()
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
