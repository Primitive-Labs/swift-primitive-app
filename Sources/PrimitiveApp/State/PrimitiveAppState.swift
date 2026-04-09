import Foundation
import SwiftUI
import os
import JsBaoClient

private let logger = Logger(subsystem: "com.primitivelabs.PrimitiveApp", category: "AppState")

/// Base state manager for Primitive apps.
///
/// Owns the `JsBaoClient` lifecycle, manages connection status, credential loading,
/// and event subscriptions. Subclass or use directly in your SwiftUI app.
///
/// Supports two modes:
/// - **Dev mode**: Uses CLI token from `~/.primitive/credentials.json` (auto-connects)
/// - **Auth mode**: Shows login UI, authenticates via OAuth/magic link/OTP, then connects
@MainActor
open class PrimitiveAppState: ObservableObject {

    // MARK: - Connection State

    @Published public var isConnected = false
    @Published public var connectionStatus: String = "Disconnected"
    @Published public var statusColor: Color = .red

    // MARK: - User Info

    @Published public var userName: String = ""
    @Published public var userEmail: String = ""
    @Published public var userAvatarUrl: String?
    @Published public var credentialSource: String = ""

    // MARK: - Documents

    @Published public var documents: [PrimitiveDocumentInfo] = []
    @Published public var selectedDocId: String?
    @Published public var isLoadingDocs = false

    // MARK: - Sync

    @Published public var isSyncing = false
    @Published public var isSynced = false
    @Published public var syncMessages: [String] = []

    // MARK: - Error

    @Published public var errorMessage: String?

    // MARK: - Auth

    /// The auth manager. Available after `initialize()` is called.
    @Published public var authManager = PrimitiveAuthManager()

    /// Whether the app is fully initialized (config loaded, client created).
    @Published public var isInitialized = false

    // MARK: - Client & Config

    public private(set) var client: JsBaoClient?
    public private(set) var appConfig: PrimitiveAppConfig?

    private var statusSubscription: EventSubscription?
    private var syncSubscription: EventSubscription?
    private var docLoadedSubscription: EventSubscription?
    private var remoteUpdateSubscription: EventSubscription?

    public init() {}

    // MARK: - Initialize

    /// Initialize the app: load config, create the client, and show the login UI.
    ///
    /// Loads app config from `primitive.json`, creates a JsBaoClient without a token,
    /// and presents the login screen. After the user authenticates, `AuthGateView`
    /// automatically calls `connectClient()`.
    ///
    /// **Dev-mode CLI auth bypass**: when `loadPrimitiveCliCredentials`
    /// returns a token (either from a bundled `dev-credentials.json` baked
    /// in by `run-ios.sh`, or from `~/.primitive/credentials.json` directly
    /// when `USE_CLI_AUTH=true` is set in `.env.local` for `./run.sh`), it
    /// gets passed straight into `JsBaoClientOptions.token`. The client is
    /// then already authenticated, the auth manager picks that up in
    /// `attach(to:)`, the login UI is skipped entirely, and
    /// `connectClient()` is invoked automatically here (since
    /// `AuthGateView`'s `.onChange(of: isAuthenticated)` only fires on
    /// transitions, not on initial state).
    public func initialize() async {
        logger.info("Initializing...")

        // Load app config from primitive.json
        let configResult = loadPrimitiveAppConfig(searchPaths: configSearchPaths())
        switch configResult {
        case .failure(let error):
            logger.error("Config error: \(error.description)")
            errorMessage = error.description
            return
        case .success(let config):
            self.appConfig = config
            credentialSource = config.appName
            logger.info("Config loaded: app=\(config.appName) server=\(config.serverUrl)")
        }

        guard let config = appConfig else { return }

        // Dev-mode CLI auth bypass. Gating lives inside the helper:
        // bundled credentials are always honored (they were placed there
        // by an explicit build-time opt-in), and ~/.primitive/credentials
        // is only consulted on macOS when `.env.local` says so.
        let cliCreds = loadPrimitiveCliCredentials(searchPaths: configSearchPaths())
        if let cli = cliCreds {
            logger.info("CLI auth bypass active for \(cli.email ?? "<unknown>")")
        }

        // Create client -- persisted JWT will be loaded automatically if available
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: config.serverUrl,
            wsUrl: config.wsUrl,
            appId: config.appId,
            token: cliCreds?.accessToken,
            offline: false,
            globalAdminAppId: "global-admin-app",
            logLevel: .info,
            storageConfig: .sqlite(),
            auth: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: config.appId),
            autoNetwork: false
        ))
        self.client = client

        setupEventSubscriptions(client)
        authManager.attach(to: client)

        // Pre-fill displayed user info from CLI creds so the profile/header
        // shows something useful before the /me round-trip lands.
        if let cli = cliCreds {
            if let name = cli.name { userName = name }
            if let email = cli.email { userEmail = email }
        }

        isInitialized = true

        // CLI bypass: connect now. The auth manager already saw the
        // bootstrapped token in attach() and flipped isAuthenticated true,
        // but AuthGateView's connect-on-auth onChange only fires on
        // transitions, so we have to kick the connect ourselves.
        if cliCreds != nil && authManager.isAuthenticated {
            await connectClient()
        }
    }

    /// Connect the client (called after auth succeeds or with a dev token).
    public func connectClient() async {
        guard let client else { return }

        connectionStatus = "Connecting..."
        statusColor = .yellow

        do {
            try await client.connect()
            addSyncMessage("Connected")
        } catch {
            errorMessage = "Connection error: \(error.localizedDescription)"
            connectionStatus = "Error"
            statusColor = .red
            return
        }

        if let me = try? await client.me.get() {
            userName = me["name"] as? String ?? ""
            userEmail = me["email"] as? String ?? ""
            userAvatarUrl = me["avatarUrl"] as? String ?? me["picture"] as? String
            if userName.isEmpty { userName = userEmail }
        }

        await fetchDocuments()
    }

    /// Override to provide additional paths to search for `primitive.json`.
    open func configSearchPaths() -> [URL] {
        return []
    }

    // MARK: - Event Subscriptions

    private func setupEventSubscriptions(_ client: JsBaoClient) {
        statusSubscription = client.events.on(.status) { [weak self] (event: StatusChangedEvent) in
            Task { @MainActor in
                guard let self else { return }
                switch event.status {
                case .connected:
                    self.isConnected = true
                    self.connectionStatus = "Connected"
                    self.statusColor = .green
                case .connecting:
                    self.connectionStatus = "Connecting..."
                    self.statusColor = .yellow
                case .disconnected:
                    self.isConnected = false
                    self.connectionStatus = "Disconnected"
                    self.statusColor = .red
                }
            }
        }

        docLoadedSubscription = client.events.on(.documentLoaded) { [weak self] (event: DocumentLoadedEvent) in
            Task { @MainActor in
                self?.addSyncMessage("Loaded from \(event.source) (\(Int(event.elapsedMs))ms)")
            }
        }

        syncSubscription = client.events.on(.sync) { [weak self] (event: SyncEvent) in
            Task { @MainActor in
                guard let self, event.documentId == self.selectedDocId else { return }
                self.isSynced = event.synced
                self.isSyncing = !event.synced
                if event.synced {
                    self.addSyncMessage("Synced")
                    self.onDocumentSynced(documentId: event.documentId)
                }
            }
        }

        remoteUpdateSubscription = client.events.on(.remoteUpdate) { [weak self] (event: RemoteUpdateEvent) in
            Task { @MainActor in
                guard let self, event.documentId == self.selectedDocId else { return }
                self.onRemoteUpdate(documentId: event.documentId)
            }
        }
    }

    /// Called when a document finishes syncing. Override to reload content.
    open func onDocumentSynced(documentId: String) {}

    /// Called when a remote update is received. Override to reload content.
    open func onRemoteUpdate(documentId: String) {}

    // MARK: - Documents

    /// Fetch the list of documents from the REST API.
    public func fetchDocuments() async {
        guard let client else { return }
        isLoadingDocs = true
        defer { isLoadingDocs = false }

        do {
            let response = try await client.documents.list(options: PaginationOptions(limit: 50))
            let items = (response["items"] ?? response["documents"]) as? [[String: Any]] ?? []
            documents = items.map { doc in
                PrimitiveDocumentInfo(
                    id: doc["documentId"] as? String ?? "",
                    title: doc["title"] as? String ?? "(untitled)",
                    permission: doc["permission"] as? String ?? "?"
                )
            }
        } catch is CancellationError {
            // Task was cancelled — normal SwiftUI lifecycle when a view with
            // `.task { fetchDocuments() }` disappears mid-fetch. Not a real
            // error; the next appearance will refetch.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Same case, but the cancellation surfaced through URLSession
            // before reaching the Swift task system.
        } catch {
            errorMessage = "Failed to fetch documents: \(error.localizedDescription)"
        }
    }

    /// Open a document and start syncing.
    public func selectDocument(_ docId: String) {
        guard let client else { return }

        if let prev = selectedDocId, prev != docId {
            Task { await client.closeDocument(prev) }
        }

        selectedDocId = docId
        syncMessages = []
        isSyncing = true
        isSynced = false

        addSyncMessage("Opening \(docId.prefix(16))...")

        Task {
            do {
                let _ = try await client.openDocument(
                    docId,
                    options: OpenDocumentOptions(waitForLoad: .network, enableNetworkSync: true)
                )
                addSyncMessage("Document opened")
                isSyncing = false
                isSynced = true
                onDocumentOpened(documentId: docId)
            } catch {
                addSyncMessage("Error: \(error)")
                errorMessage = "Failed to open document: \(error.localizedDescription)"
                isSyncing = false
            }
        }
    }

    /// Called after a document is successfully opened. Override to set up BaoModels.
    open func onDocumentOpened(documentId: String) {}

    // MARK: - Sync Messages

    public func addSyncMessage(_ msg: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        syncMessages.insert("[\(timestamp)] \(msg)", at: 0)
        if syncMessages.count > 100 {
            syncMessages = Array(syncMessages.prefix(100))
        }
    }

    // MARK: - Cleanup

    public func cleanup() async {
        authManager.detach()
        statusSubscription?.cancel()
        syncSubscription?.cancel()
        docLoadedSubscription?.cancel()
        remoteUpdateSubscription?.cancel()
        if let client { await client.destroy() }
    }
}

/// Metadata about a Primitive document.
public struct PrimitiveDocumentInfo: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let permission: String

    public init(id: String, title: String, permission: String) {
        self.id = id
        self.title = title
        self.permission = permission
    }
}

// MARK: - ULID Generator

private let ulidChars = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

/// Generate a ULID (Universally Unique Lexicographically Sortable Identifier).
public func generateULID() -> String {
    let now = UInt64(Date().timeIntervalSince1970 * 1000)
    var timestamp = now
    var timeChars = [Character](repeating: "0", count: 10)
    for i in stride(from: 9, through: 0, by: -1) {
        timeChars[i] = ulidChars[Int(timestamp & 0x1F)]
        timestamp >>= 5
    }
    var randomChars = [Character](repeating: "0", count: 16)
    for i in 0..<16 {
        randomChars[i] = ulidChars[Int.random(in: 0..<32)]
    }
    return String(timeChars) + String(randomChars)
}
