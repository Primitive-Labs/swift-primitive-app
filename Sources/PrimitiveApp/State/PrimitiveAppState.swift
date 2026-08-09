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
    private var documentSyncStateSubscription: EventSubscription?

    public init() {}

    // MARK: - Initialize

    /// Initialize the app: load config, create the client, and show the login UI.
    ///
    /// Loads app config from `primitive.json`, creates a JsBaoClient without a token,
    /// and presents the login screen. After the user authenticates, `AuthGateView`
    /// automatically calls `connectClient()`.
    ///
    /// For a fast dev loop that skips typing a real OTP, use test-user
    /// sign-in: whitelist a base email in the app's settings
    /// (`testAccountBaseEmails`), then sign in through the normal login UI
    /// as the `+primitivetest` derivative address with code `000000`.
    open func initialize() async {
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

        // Create client -- persisted JWT will be loaded automatically if available
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: config.serverUrl,
            wsUrl: config.wsUrl,
            appId: config.appId,
            token: nil,
            offline: false,
            globalAdminAppId: "global-admin-app",
            logLevel: .info,
            storageConfig: .sqlite(),
            auth: AuthConfig(persistJwtInStorage: true, storageKeyPrefix: config.appId),
            autoNetwork: false
        ))
        self.client = client

        // Wire the process-wide default the codegen'd model facade reads
        // (`TaskRecord.query()`, `record.save(in:)`, `TaskRecord.subscribe`).
        // Must happen before any generated `Model.*` call, so we do it as
        // soon as the client exists.
        JsBaoClient.configureDefault(client)

        setupEventSubscriptions(client)
        authManager.attach(to: client)

        #if DEBUG
        DebugInspector.start(client: client, appState: self, appConfig: config)
        #endif

        isInitialized = true
    }

    /// Connect the client (called after auth succeeds).
    ///
    /// Subclasses may override to run app-specific setup after the
    /// websocket is up (e.g. resolve a per-user singleton doc, bind
    /// models). Call `super.connectClient()` first so the base
    /// class still connects, hydrates `userName`, and fetches the
    /// document list.
    open func connectClient() async {
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
            // `me.get()` is now a typed `UserProfile` (was a raw dict).
            userName = me.name ?? ""
            userEmail = me.email
            userAvatarUrl = me.avatarUrl
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
        // `observeOnMainActor` delivers on the main actor, so these handlers
        // touch `@MainActor` state directly — no `Task { @MainActor in }`
        // wrapper. No replay of the last-known status is needed either: this
        // runs while the client is being wired, before `connect()`, so nothing
        // has been emitted yet. (Replay is a `stream(for:)` option; this call
        // site has no such parameter.)
        statusSubscription = client.observeOnMainActor(StatusChangedEvent.self) { [weak self] event in
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

        docLoadedSubscription = client.observeOnMainActor(DocumentLoadedEvent.self) { [weak self] event in
            self?.addSyncMessage("Loaded from \(event.source) (\(Int(event.elapsedMs))ms)")
        }

        syncSubscription = client.observeOnMainActor(SyncEvent.self) { [weak self] event in
            guard let self, event.documentId == self.selectedDocId else { return }
            self.isSynced = event.synced
            self.isSyncing = !event.synced
            if event.synced {
                self.addSyncMessage("Synced")
                self.onDocumentSynced(documentId: event.documentId)
            }
        }

        documentSyncStateSubscription = client.observeOnMainActor(DocumentSyncStateChangedEvent.self) { [weak self] event in
            guard let self,
                  event.documentId == self.selectedDocId,
                  event.state == "synced"
            else { return }
            self.onDocumentSyncStateChanged(documentId: event.documentId, state: event.state)
        }
    }

    /// Called when a document finishes syncing. Override to reload content.
    open func onDocumentSynced(documentId: String) {}

    /// Called when document sync state changes after a remote write lands.
    /// Override to reload content.
    open func onDocumentSyncStateChanged(documentId: String, state: String) {}

    // MARK: - Documents

    /// Fetch the list of documents from the REST API.
    public func fetchDocuments() async {
        guard let client else { return }
        isLoadingDocs = true
        defer { isLoadingDocs = false }

        do {
            // Compose the owned + shared union inline (the client exposes only
            // `ownedDocuments` / `sharedDocuments`, 1:1 with the JS app layer;
            // both replace the deprecated `documents.list()`). Owned wins on
            // overlap.
            async let ownedTask = client.me.ownedDocuments(limit: 50)
            async let sharedTask = client.me.sharedDocuments(limit: 50)
            let owned = try await ownedTask
            let shared = try await sharedTask

            var seen = Set<String>()
            var merged: [PrimitiveDocumentInfo] = []
            for info in owned where seen.insert(info.documentId).inserted {
                merged.append(PrimitiveDocumentInfo(
                    id: info.documentId, title: info.title, permission: info.permission.rawValue))
            }
            for share in shared.items where seen.insert(share.document.documentId).inserted {
                merged.append(PrimitiveDocumentInfo(
                    id: share.document.documentId,
                    title: share.document.title,
                    permission: share.document.permission.rawValue))
            }
            documents = merged
        } catch is CancellationError {
            // Task was cancelled — normal SwiftUI lifecycle when a view with
            // `.task { fetchDocuments() }` disappears mid-fetch. Not a real
            // error; the next appearance will refetch. The client normalizes
            // a `URLSession` cancellation into `CancellationError` too, so
            // this one clause covers both routes.
        } catch {
            errorMessage = "Failed to fetch documents: \(error.localizedDescription)"
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
    /// opening a doc over IPC and then querying the model facade for the
    /// just-connected document.
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
            // `.localIfAvailableElseNetwork` resolves immediately when a
            // local copy exists (the common case after the first launch,
            // and the case for freshly-created docs from
            // `getOrCreateWithAlias` whose initial open populates the
            // local store). With `.network` here, brand-new empty docs
            // park up to 15s in `JsBaoClient.openDocument` waiting for a
            // `.sync(synced: true)` event that won't fire until there's
            // actual server content to deliver. Sync still progresses in
            // the background; views bound through `BaoDataLoader` with
            // `.onModelChange` / `.onSync` reload as content arrives.
            let doc = try await client.openDocument(
                docId,
                options: OpenDocumentOptions(
                    waitForLoad: .localIfAvailableElseNetwork,
                    enableNetworkSync: true
                )
            )
            addSyncMessage("Document opened")
            isSyncing = false
            isSynced = true
            await onDocumentOpened(doc: doc, documentId: docId)
        } catch {
            addSyncMessage("Error: \(error)")
            errorMessage = "Failed to open document: \(error.localizedDescription)"
            isSyncing = false
        }
    }

    /// Called after a document is successfully opened — the **preferred**
    /// override point.
    ///
    /// The document is now connected to the client's shared model store, so
    /// the codegen'd model facade can read it immediately — no per-doc model
    /// binding needed:
    ///
    /// ```swift
    /// override func onDocumentOpened(doc: YDocument, documentId: String) async {
    ///     todos = TodoItem.query()   // cross-doc; or scope with QueryOptions(documents:)
    /// }
    /// ```
    ///
    /// Default implementation forwards to the legacy
    /// `onDocumentOpened(documentId:)` hook so existing subclasses keep
    /// working — but new code should override **this** overload.
    open func onDocumentOpened(doc: YDocument, documentId: String) async {
        onDocumentOpened(documentId: documentId)
    }

    /// ⚠️ LEGACY / NON-BINDING hook — kept only for back-compat.
    ///
    /// This overload does **NOT** hand you the `YDocument`, so it fires
    /// before you have a handle to seed initial state from. Overriding
    /// *this* instead of the `doc:documentId:` overload above is a common
    /// mistake: it compiles and runs, but you never get the doc handle —
    /// with no error to point at the cause.
    ///
    /// ✅ To bind models, override `onDocumentOpened(doc:documentId:)` — it
    /// gives you the live `YDocument` directly. Only override THIS one if
    /// you genuinely want a doc-id-only lifecycle notification (and will do
    /// your own `openDocument(...)`), which is wasteful and racy for binding.
    open func onDocumentOpened(documentId: String) {}

    // MARK: - Sync Messages

    public func addSyncMessage(_ msg: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        syncMessages.insert("[\(timestamp)] \(msg)", at: 0)
        if syncMessages.count > 100 {
            syncMessages = Array(syncMessages.prefix(100))
        }
    }

    // MARK: - Inspectable models

    /// Every model the client is mirroring, across all open documents,
    /// surfaced to the debug inspector. Pulled from the client's shared
    /// cross-document store (`inspectableSharedMembers`) — one entry per
    /// `(model, open document)` pair — so the inspector reflects exactly
    /// what the codegen'd `Model.*` facade reads and writes. No per-doc
    /// model binding or registration is required; a model appears here as
    /// soon as it's been queried or written once (which registers it with
    /// the shared store).
    ///
    /// Subclasses may `override` to filter or supplement this list (e.g.
    /// hide internal models, or add a `DynamicModel` not bound through the
    /// facade).
    @MainActor
    open var inspectableModels: [InspectableModel] {
        guard let client else { return [] }
        return client.inspectableSharedMembers().map { member in
            InspectableModel.from(
                member.model,
                documentId: member.documentId,
                name: member.modelName
            )
        }
    }

    // MARK: - Auxiliary documents (multi-doc apps)
    //
    // `selectDocumentAwaiting(_:)` is the single-selected-doc lifecycle:
    // it closes the previous selection before opening the new one,
    // updates `selectedDocId`, routes sync-state hooks, and fires
    // `onDocumentOpened(doc:documentId:)`. That fits "one document per
    // user" apps. It doesn't fit apps that keep one ambient doc open
    // (e.g. a library / index doc) while opening and closing N other
    // docs alongside it — calling `selectDocumentAwaiting` for a list
    // detail view would close the ambient library doc.
    //
    // `openAuxiliaryDoc(_:)` is the multi-doc primitive: it opens a doc
    // through the same `JsBaoClient.openDocument(...)` path so the
    // DocumentManager registers it for sync, but **does not touch**
    // `selectedDocId` or call `onDocumentOpened`. The caller owns the
    // lifecycle — typically a SwiftUI detail view that opens in `.task`
    // and closes in `.onDisappear`. Once the doc is open, read/write its
    // records through the codegen'd model facade scoped to that doc —
    // `TodoItem.query(options: QueryOptions(documents: [documentId]))`
    // for reads, `try TodoItem(...).save(in: documentId)` for writes.
    //
    // Usage:
    //
    //     // In your TodoListDetailView:
    //     .task {
    //         try await appState.openAuxiliaryDoc(documentId)
    //         self.todos = TodoItem.query(
    //             options: QueryOptions(documents: [documentId])
    //         )
    //     }
    //     .onDisappear {
    //         Task { await appState.closeAuxiliaryDoc(documentId) }
    //     }

    /// Open a document outside the single-selected-doc lifecycle and
    /// return its `YDocument`. Does NOT update `selectedDocId` or call
    /// `onDocumentOpened`. See block comment above.
    ///
    /// Closing is the caller's responsibility — typically from
    /// `.onDisappear`. The `JsBaoClient.openDocument(...)` call is
    /// idempotent: opening the same id twice returns the same
    /// `YDocument` and doesn't double-register sync.
    @MainActor
    public func openAuxiliaryDoc(
        _ documentId: String,
        waitForLoad: WaitForLoadMode = .localIfAvailableElseNetwork,
        enableNetworkSync: Bool = true
    ) async throws -> YDocument {
        guard let client else {
            throw JsBaoError(
                code: .unavailable,
                message: "openAuxiliaryDoc requires an initialized client"
            )
        }
        return try await client.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: waitForLoad,
            enableNetworkSync: enableNetworkSync
        ))
    }

    /// Close an auxiliary doc that was opened via `openAuxiliaryDoc`.
    /// Safe to call on the currently selected doc too — though if it's
    /// the selected doc, prefer to switch via `selectDocumentAwaiting`
    /// instead so the base bookkeeping (`selectedDocId`, sync routing)
    /// is correctly cleared.
    @MainActor
    public func closeAuxiliaryDoc(_ documentId: String) async {
        await client?.closeDocument(documentId)
    }

    // MARK: - Cleanup

    public func cleanup() async {
        authManager.detach()
        statusSubscription?.cancel()
        syncSubscription?.cancel()
        docLoadedSubscription?.cancel()
        documentSyncStateSubscription?.cancel()
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
