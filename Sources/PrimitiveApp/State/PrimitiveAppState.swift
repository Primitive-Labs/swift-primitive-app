import Foundation
import SwiftUI
import os
import JsBaoClient
import YSwift

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
    /// Fires when the local metadata cache for any document changes —
    /// covers the REST create path (via the swift-client hook on
    /// `DocumentsAPI.create`), the offline-first local-create path,
    /// bulk server-list refreshes, and server-pushed `docMetadata` WS
    /// frames (e.g. another device of the same user created a doc, or
    /// another user shared one in). On fire we re-fetch the document
    /// list so `documents` reflects the change — keeps the inspector
    /// and any reactive consumers honest without requiring the host
    /// app to manually call `fetchDocuments()` after every mutation.
    private var documentMetadataSubscription: EventSubscription?
    /// Coalesces bursts of `.documentMetadataChanged` fires (e.g. a
    /// bulk-doc sync emits one per row) into a single REST refresh.
    private var pendingDocumentRefresh: Task<Void, Never>?

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

        #if DEBUG
        DebugInspector.start(client: client, appState: self, appConfig: config)
        #endif

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

        documentMetadataSubscription = client.events.on(.documentMetadataChanged) { [weak self] (_: [String: Any]) in
            Task { @MainActor in
                self?.scheduleDocumentRefresh()
            }
        }
    }

    /// Coalesce bursts of `.documentMetadataChanged` (one per row for a
    /// bulk sync, plus the rich re-emit from the WS handler) into a
    /// single REST refresh. ~50ms debounce — short enough to feel live,
    /// long enough to swallow a `serverDocuments` batch.
    private func scheduleDocumentRefresh() {
        pendingDocumentRefresh?.cancel()
        pendingDocumentRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
            await self?.fetchDocuments()
        }
    }

    /// Called when a document finishes syncing. Override to reload content.
    open func onDocumentSynced(documentId: String) {}

    /// Called when a remote update is received. Override to reload content.
    open func onRemoteUpdate(documentId: String) {}

    // MARK: - Documents

    /// Fetch the list of documents from the REST API and union it with
    /// the swift-client's local metadata cache.
    ///
    /// `GET /documents` only returns docs with a direct `DocumentPermission`
    /// row — cascade-accessible docs (e.g. a refs doc shared via a
    /// collection's group permission) don't appear there. The local
    /// cache, populated by `openDocument`'s auto-fetch and by the WS
    /// `docMetadata` handler in swift-client, IS the canonical source
    /// for "all docs I know about." Read the REST list first (so cache
    /// gets refreshed by the underlying `handleServerDocuments` call),
    /// then rebuild `documents` from the merged cache.
    public func fetchDocuments() async {
        guard let client else { return }
        isLoadingDocs = true
        defer { isLoadingDocs = false }

        do {
            _ = try await client.documents.list(options: PaginationOptions(limit: 50))
        } catch is CancellationError {
            // Task was cancelled — normal SwiftUI lifecycle when a view with
            // `.task { fetchDocuments() }` disappears mid-fetch. Not a real
            // error; the next appearance will refetch.
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Same case, but the cancellation surfaced through URLSession
            // before reaching the Swift task system.
            return
        } catch {
            errorMessage = "Failed to fetch documents: \(error.localizedDescription)"
            // Fall through — still rebuild from the local cache so we
            // don't blow away existing entries on a transient REST blip.
        }

        rebuildDocumentsFromLocalCache(client: client)
    }

    /// Rebuild `documents` from the swift-client's local metadata cache.
    /// The cache is the union of every doc we've seen (REST list, opened
    /// cascade docs, locally-created docs, WS metadata broadcasts), so
    /// this gives a complete snapshot — unlike `documents.list` which
    /// drops cascade-accessible rows.
    private func rebuildDocumentsFromLocalCache(client: JsBaoClient) {
        let snapshot = client.getAllLocalDocumentMetadata()
        documents = snapshot.values.map { entry in
            PrimitiveDocumentInfo(
                id: entry.documentId,
                title: entry.title ?? "(untitled)",
                permission: entry.permission ?? "?"
            )
        }
    }

    /// Open a document and start syncing. Fire-and-forget — the caller
    /// gets control back immediately; the sync progresses in the
    /// background, and `onDocumentOpened(documentId:)` fires when it
    /// lands.
    public func selectDocument(_ docId: String) {
        Task { await selectDocumentAwaiting(docId) }
    }

    /// Await variant of `selectDocument`. Returns only after the open
    /// has completed, the doc is synced, and the subclass's
    /// `onDocumentOpened(documentId:)` hook has run.
    ///
    /// Use this when the caller needs the app's post-open state to be
    /// fully in place before continuing — e.g. the debug inspector
    /// opening a doc over IPC and then querying the just-rebound
    /// `BaoModel` / `TypedModel` instances.
    @MainActor
    public func selectDocumentAwaiting(_ docId: String) async {
        guard let client else { return }

        if let prev = selectedDocId, prev != docId {
            await client.closeDocument(prev)
        }

        selectedDocId = docId
        syncMessages = []
        isSyncing = true
        isSynced = false

        addSyncMessage("Opening \(docId.prefix(16))...")

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

    // MARK: - Inspectable model registry

    /// One entry per registered `TypedModel`/`DynamicModel`. Stored as a weak
    /// builder closure so the underlying model can deallocate when the host
    /// drops its reference (e.g. doc closed) — the next read of
    /// `inspectableModels` compacts dead entries away.
    fileprivate struct RegisteredInspectable {
        let documentId: String
        let name: String
        let build: @MainActor () -> InspectableModel?
    }

    fileprivate var inspectableRegistry: [RegisteredInspectable] = []

    /// Every model registered via `makeTypedModel(...)`, surfaced to the debug
    /// inspector. Subclasses may `override` for custom behaviour; the default
    /// covers the common "register-on-construction" path so most hosts don't
    /// need to write any inspector glue.
    @MainActor
    open var inspectableModels: [InspectableModel] {
        var alive: [RegisteredInspectable] = []
        var out: [InspectableModel] = []
        for entry in inspectableRegistry {
            if let m = entry.build() {
                alive.append(entry)
                out.append(m)
            }
        }
        if alive.count != inspectableRegistry.count {
            inspectableRegistry = alive
        }
        return out
    }

    /// Construct a `TypedModel<T>` and register it with the inspector in one
    /// step. Replaces any prior entry with the same `(documentId, modelName)`
    /// so doc-reopen and doc-swap cases produce a single live entry rather
    /// than stacking duplicates.
    @MainActor
    public func makeTypedModel<T: PrimitiveModel>(
        doc: YDocument,
        documentId: String,
        name: String? = nil
    ) -> TypedModel<T> {
        let model = TypedModel<T>(doc: doc)
        let modelName = name ?? T.modelName
        inspectableRegistry.removeAll {
            $0.documentId == documentId && $0.name == modelName
        }
        inspectableRegistry.append(RegisteredInspectable(
            documentId: documentId,
            name: modelName,
            build: { [weak model] in
                guard let model else { return nil }
                return .from(model, documentId: documentId, name: modelName)
            }
        ))
        return model
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
