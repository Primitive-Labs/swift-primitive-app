import SwiftUI

/// One-time "add a passkey?" sheet, presented by `AuthGateView` right after
/// a first interactive (non-passkey) sign-in when the app supports passkeys
/// — the standard iOS enrollment nudge. "Add Passkey" runs the system
/// Face ID / Touch ID sheet via `PrimitiveAuthManager.enrollPasskey()`;
/// "Not Now" (or swipe-dismiss) records the decline so the user is never
/// auto-prompted again on this device.
public struct PasskeyEnrollmentView: View {
    @ObservedObject var authManager: PrimitiveAuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var isEnrolling = false
    @State private var enrollError: String?

    public init(authManager: PrimitiveAuthManager) {
        self.authManager = authManager
    }

    public var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Sign in faster next time")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Add a passkey to sign in with Face ID or Touch ID — no email codes, nothing to remember. It's saved to your iCloud Keychain.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let enrollError {
                Text(enrollError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    Task {
                        isEnrolling = true
                        enrollError = nil
                        let ok = await authManager.enrollPasskey()
                        isEnrolling = false
                        if ok {
                            dismiss()
                        } else if let err = authManager.authError {
                            enrollError = err
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isEnrolling {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "faceid")
                        }
                        Text("Add Passkey")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isEnrolling)

                Button("Not Now") {
                    authManager.declinePasskeyEnrollment()
                    dismiss()
                }
                .font(.subheadline)
            }
        }
        .padding(28)
    }
}
