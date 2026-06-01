import SwiftUI

/// User profile page showing avatar, name, email, and logout button.
///
/// Developer info (connection status, app name) is shown when:
/// - `showDeveloperInfo` is explicitly set to `true`, OR
/// - The `PRIMITIVE_DEV` environment variable is set (e.g. via Xcode scheme)
///
/// In release builds without the env var, developer info is hidden by default.
public struct PrimitiveProfileView: View {
    @ObservedObject var appState: PrimitiveAppState
    @ObservedObject var authManager: PrimitiveAuthManager
    var showDeveloperInfo: Bool

    /// - Parameter appState: The app's `PrimitiveAppState` instance. Passed
    ///   explicitly rather than read from `@EnvironmentObject` so subclasses
    ///   work (see `ConnectionStatusView` for the underlying SwiftUI
    ///   exact-runtime-type limitation).
    public init(appState: PrimitiveAppState, authManager: PrimitiveAuthManager, showDeveloperInfo: Bool? = nil) {
        self.appState = appState
        self.authManager = authManager
        if let explicit = showDeveloperInfo {
            self.showDeveloperInfo = explicit
        } else {
            // Auto-detect: show in debug builds or when PRIMITIVE_DEV env var is set
            #if DEBUG
            self.showDeveloperInfo = true
            #else
            self.showDeveloperInfo = ProcessInfo.processInfo.environment["PRIMITIVE_DEV"] != nil
            #endif
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            List {
                // Profile header
                Section {
                    HStack(spacing: 16) {
                        avatarView
                            .frame(width: 64, height: 64)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(appState.userName)
                                .font(.title3)
                                .fontWeight(.semibold)
                            if !appState.userEmail.isEmpty && appState.userEmail != appState.userName {
                                Text(appState.userEmail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                // Connection info (developer mode only)
                if showDeveloperInfo {
                    Section("Developer") {
                        HStack {
                            Text("Status")
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(appState.statusColor)
                                    .frame(width: 8, height: 8)
                                Text(appState.connectionStatus)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            Text("App")
                            Spacer()
                            Text(appState.credentialSource)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Logout
                Section {
                    Button(role: .destructive) {
                        Task { await authManager.logout() }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Sign Out")
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle("Profile")
    }

    @ViewBuilder
    private var avatarView: some View {
        if let urlString = appState.userAvatarUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                avatarPlaceholder
            }
            .clipShape(Circle())
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.15))
            .overlay(
                Text(initials)
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
            )
    }

    private var initials: String {
        let parts = appState.userName.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(appState.userName.prefix(2)).uppercased()
    }
}
