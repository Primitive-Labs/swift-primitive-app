import SwiftUI

/// Toolbar-ready view showing connection status dot, status text, and user name.
///
/// Takes `appState` as an explicit parameter rather than reading it from the
/// environment. `@EnvironmentObject var appState: PrimitiveAppState` would
/// only resolve when the parent injected an instance whose RUNTIME type is
/// exactly `PrimitiveAppState` — a subclass (e.g. an app's `MyAppState`) is
/// stored under its own type key and the lookup traps. Passing the state
/// explicitly is subclass-safe.
public struct ConnectionStatusView: View {
    @ObservedObject var appState: PrimitiveAppState

    public init(appState: PrimitiveAppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.statusColor)
                .frame(width: 8, height: 8)
                // VoiceOver: the dot conveys connection state visually, so
                // expose the same info to assistive tech instead of leaving
                // a bare circle. The text label next to it carries the same
                // information visually but isn't always read in toolbar
                // placements, so we label the dot too and merge the row.
                .accessibilityLabel("Connection status: \(appState.connectionStatus)")
            Text(appState.connectionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !appState.userName.isEmpty {
                Text("\u{00B7}").foregroundStyle(.secondary)
                Text(appState.userName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Full-screen loading view with a spinner and status message.
public struct PrimitiveLoadingView: View {
    let message: String

    public init(_ message: String = "Loading...") {
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Gates content behind authentication + connection.
///
/// Shows login UI when unauthenticated, loading state while connecting,
/// and the provided content once connected.
public struct AuthGateView<Content: View>: View {
    @ObservedObject var appState: PrimitiveAppState
    @ObservedObject var authManager: PrimitiveAuthManager
    let appName: String
    let content: () -> Content

    /// - Parameter appState: The app's `PrimitiveAppState` instance. Passed
    ///   explicitly (rather than read from `@EnvironmentObject`) so that
    ///   apps subclassing `PrimitiveAppState` can use this view without
    ///   tripping SwiftUI's exact-runtime-type lookup. See the type-level
    ///   doc-comment on `ConnectionStatusView` for the underlying SwiftUI
    ///   limitation.
    ///
    /// The login screen's sign-in buttons (Google #928, Apple #409,
    /// passkeys #929, email) are driven by the server's auth config —
    /// see `PrimitiveAuthManager.availableProviders` — so there's nothing
    /// to configure here. After a first interactive sign-in the gate also
    /// presents the one-time "add a passkey?" enrollment sheet when the
    /// app supports passkeys.
    public init(
        appState: PrimitiveAppState,
        appName: String = "Primitive",
        authManager: PrimitiveAuthManager,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.appState = appState
        self.appName = appName
        self.authManager = authManager
        self.content = content
    }

    /// Track whether we've ever connected (to distinguish first connect from offline)
    @State private var hasConnectedOnce = false

    public var body: some View {
        ZStack {
            if !appState.isInitialized {
                PrimitiveLoadingView("Initializing...")
            } else if authManager.isAuthRestoring && !authManager.isAuthenticated {
                // The client is still attempting a cookie-based session
                // refresh (access token aged out but the refresh cookie
                // is live). Hold on a loading view instead of flashing
                // the login screen for the ~1–2s the refresh takes.
                PrimitiveLoadingView("Restoring session...")
            } else if !authManager.isAuthenticated && appState.client != nil {
                PrimitiveLoginView(appName: appName, authManager: authManager)
            } else if appState.isConnected || hasConnectedOnce {
                // Show content when connected OR when we were connected before (offline mode)
                content()
            } else if appState.errorMessage != nil {
                errorView
            } else {
                PrimitiveLoadingView("Connecting...")
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, authenticated in
            if authenticated && !appState.isConnected {
                Task { await appState.connectClient() }
            }
        }
        .onChange(of: appState.isConnected) { _, connected in
            if connected { hasConnectedOnce = true }
        }
        // One-time post-sign-in nudge (standard iOS pattern): the user just
        // signed in with something slower than a passkey and the app
        // supports passkeys — offer to add one. Swipe-dismiss counts as
        // "Not Now" so the user is never nagged twice.
        .sheet(isPresented: $authManager.shouldOfferPasskeyEnrollment,
               onDismiss: {
                   if authManager.shouldOfferPasskeyEnrollment == false
                       && !authManager.hasLocalPasskeyHint {
                       authManager.declinePasskeyEnrollment()
                   }
               }) {
            PasskeyEnrollmentView(authManager: authManager)
                .presentationDetents([.medium])
        }
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(appState.errorMessage ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") {
                appState.errorMessage = nil
                Task { await appState.initialize() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sidebar view showing the list of documents with selection support.
///
/// See `ConnectionStatusView` for why `appState` is an explicit parameter
/// rather than `@EnvironmentObject`.
public struct DocumentSidebarView: View {
    @ObservedObject var appState: PrimitiveAppState

    public init(appState: PrimitiveAppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(appState.credentialSource)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if appState.isLoadingDocs {
                    ProgressView().scaleEffect(0.6)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if appState.documents.isEmpty && !appState.isLoadingDocs {
                VStack(spacing: 8) {
                    Text("No documents").foregroundStyle(.secondary)
                    Text("Create one in the web app")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.documents, selection: $appState.selectedDocId) { doc in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.title)
                            .fontWeight(appState.selectedDocId == doc.id ? .semibold : .regular)
                        Text(doc.id.prefix(16) + "...")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospaced()
                    }
                    .tag(doc.id)
                    .padding(.vertical, 2)
                }
                .onChange(of: appState.selectedDocId) { _, newValue in
                    if let docId = newValue {
                        appState.selectDocument(docId)
                    }
                }
            }
        }
        .frame(minWidth: 220)
    }
}
