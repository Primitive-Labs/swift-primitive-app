#if DEBUG
import Foundation
import JsBaoClient

/// Local HTTP inspector that exposes JsBaoClient internals for debugging.
///
/// Starts automatically from `PrimitiveAppState.initialize()` in DEBUG builds. Serves a
/// self-contained web UI at `http://<host>:9999/` that shows:
///   - connection + auth state, user info
///   - open / known / pending documents with their sync state
///   - the contents of the local SQLite kv store (read-only)
///   - a live SSE stream of JsBaoClient events
///   - per-doc open timelines (sqlite load → server sync → ready) for performance debugging
///   - the host app's registered `InspectableModel`s and their records
///
/// Release builds exclude this entire file via `#if DEBUG`, so there is zero production footprint.
///
/// Opt-out: set `PRIMITIVE_DEBUG_INSPECTOR=0` in the environment.
/// Port: defaults to 9999. Override via `PRIMITIVE_DEBUG_INSPECTOR_PORT`.
public final class DebugInspector: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = DebugInspector()
    private init() {}

    // MARK: - Public entry

    /// Start the inspector server. Idempotent — subsequent calls are no-ops.
    @MainActor
    public static func start(client: JsBaoClient, appState: PrimitiveAppState, appConfig: PrimitiveAppConfig) {
        shared.startInternal(client: client, appState: appState, appConfig: appConfig)
    }

    // MARK: - State

    private let lock = NSLock()
    private var started = false
    private weak var client: JsBaoClient?
    private weak var appState: PrimitiveAppState?
    private var appConfig: PrimitiveAppConfig?
    private var sqlite: InspectorSQLiteReader?

    private var server: DebugHTTPServer?
    private var subscriptions: [EventSubscription] = []

    /// Ring buffer of recent events, newest last. Capped at `maxEvents` so memory stays bounded.
    private var events: [[String: Any]] = []
    private let maxEvents = 500
    private var sseChannels: [SSEChannel] = []

    // Performance timeline is derived client-side from the live SSE
    // event stream — no server-side phase buffer needed. See
    // tabs/performance.js `perfPhaseFromEvent`.

    // MARK: - Start / Stop

    @MainActor
    private func startInternal(client: JsBaoClient, appState: PrimitiveAppState, appConfig: PrimitiveAppConfig) {
        let env = ProcessInfo.processInfo.environment
        if env["PRIMITIVE_DEBUG_INSPECTOR"] == "0" { return }

        lock.lock()
        if started { lock.unlock(); return }
        started = true
        self.client = client
        self.appState = appState
        self.appConfig = appConfig
        self.sqlite = InspectorSQLiteReader(appId: appConfig.appId)
        lock.unlock()

        subscribeToEvents(client)

        let envPort = env["PRIMITIVE_DEBUG_INSPECTOR_PORT"].flatMap(Int.init)
        let port = UInt16(envPort ?? 9999)
        let attempts = envPort != nil ? 1 : 8
        startServer(port: port, attemptsLeft: attempts)
    }

    /// Tracks whether the current `self.server` ever reached `.ready`.
    /// We use this to distinguish "port collision before bind" (legitimate
    /// reason to climb to port+1) from "the listener came up and later
    /// failed" (retrying with port+1 just spams banners and never
    /// resolves the underlying cause — e.g. bonjour name collision,
    /// Local Network permission, network interface bounce).
    private var listenerReadyOnce = false

    private func startServer(port: UInt16, attemptsLeft: Int) {
        // Per-instance bonjour name so two devices (or sim+device)
        // running the same appId don't collide on mDNS registration.
        // The conflict path was: A registers `app.id`, B tries to
        // register `app.id` too, B's listener goes `.ready` then
        // immediately `.failed` because Bonjour rejects the duplicate.
        // Differentiator: short hash of (hostname, PID, port). Stable
        // within a run, unique across instances.
        let appId = appConfig?.appId ?? "primitive"
        let host = ProcessInfo.processInfo.hostName
        let pid = ProcessInfo.processInfo.processIdentifier
        let suffix = String(
            (host + "-\(pid)-\(port)").hashValue & 0xFFFFFF,
            radix: 36,
            uppercase: false
        )
        // Keep within mDNS's 63-byte limit. appId takes priority so
        // browsers can still group instances by app.
        let bonjourName = String("\(appId)-\(suffix)".prefix(60))

        let server = DebugHTTPServer(port: port, bonjourName: bonjourName) { [weak self] request, writer in
            self?.route(request, writer)
        }
        do {
            try server.start { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listenerReadyOnce = true
                    self.printBanner(port: port)
                case .failed(let err):
                    server.stop()
                    // Only climb to port+1 if the listener never came
                    // up — that's the genuine "port collision" path.
                    // A post-`.ready` `.failed` means something else
                    // killed our bound listener (bonjour conflict,
                    // network drop, app suspended) and the next port
                    // will hit the same wall.
                    if self.listenerReadyOnce {
                        let appLabel = self.appConfig?.appId ?? "?"
                        inspectorLog("\(appLabel): listener on port \(port) went .ready then .failed: \(err). Not retrying — the cause isn't a port collision.", level: "error")
                        return
                    }
                    if attemptsLeft > 1 {
                        self.startServer(port: port &+ 1, attemptsLeft: attemptsLeft - 1)
                    } else {
                        let appLabel = self.appConfig?.appId ?? "?"
                        inspectorLog("\(appLabel): gave up after trying up to port \(port): \(err). Set PRIMITIVE_DEBUG_INSPECTOR_PORT to pin a specific port.", level: "error")
                    }
                default:
                    break
                }
            }
            self.server = server
        } catch {
            if attemptsLeft > 1 {
                startServer(port: port &+ 1, attemptsLeft: attemptsLeft - 1)
            } else {
                inspectorLog("could not create listener on port \(port): \(error)", level: "error")
            }
        }
    }

    private func printBanner(port: UInt16) {
        let urls = reachableURLs(port: port)
        let appLabel = appConfig?.appId ?? "?"
        // Dual-emit on purpose. `inspectorLog` routes through os_log,
        // which `simctl spawn <udid> log stream` (simulator path) and
        // Console.app on Mac (device path via Mac sidebar) DO capture
        // but `devicectl process launch --console` (run-ios.sh's
        // device path) does NOT — it only reads the process's
        // stdout/stderr. The banner is the one inspector line every
        // user always wants to see, so we also print() it: on device,
        // that lands in --console alongside BootTiming's `[boot]`
        // marks. The os_log copy stays so Console.app filters keep
        // working and the line is retained in the unified log.
        inspectorLog("\(appLabel) listening on port \(port) — \(urls.count) URL(s)")
        print("[primitive-inspector] \(appLabel) listening on port \(port) — \(urls.count) URL(s)")
        for url in urls {
            inspectorLog("  \(url)")
            print("[primitive-inspector]   \(url)")
        }
    }

    private func reachableURLs(port: UInt16) -> [String] {
        var urls: [String] = []
        #if targetEnvironment(simulator) || os(macOS)
        urls.append("http://localhost:\(port)")
        #endif
        for ip in Self.localIPAddresses() where ip != "127.0.0.1" {
            urls.append("http://\(ip):\(port)")
        }
        return urls
    }

    private static func localIPAddresses() -> [String] {
        var results: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return results }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            let addr = cur.pointee.ifa_addr.pointee
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  addr.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            // Keep only Wi-Fi / Ethernet. On iOS: en0 = Wi-Fi. On macOS: en0 = Wi-Fi,
            // en1 = Ethernet. Filter out pdp_ip* (cellular), utun* (VPN / Private
            // Relay), awdl* (AirDrop peer), llw* — their IPs exist on the phone but
            // aren't routable from the dev's Mac, so printing them just confuses.
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(cur.pointee.ifa_addr,
                           socklen_t(cur.pointee.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                results.append(String(cString: host))
            }
        }
        return results
    }

    // MARK: - Routing

    private func route(_ request: DebugHTTPServer.Request, _ writer: ResponseWriter) {
        let path = request.path
        // Static UI
        if path == "/" {
            writer.respond(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(InspectorHTML.page.utf8)
            )
            return
        }
        // Read endpoints
        if request.method == "GET" {
            switch path {
            case "/api/snapshot":
                Task { [weak self] in
                    let snap = await self?.buildSnapshot() ?? [:]
                    writer.respondJSON(snap)
                }
                return
            case "/api/events":
                handleEventsStream(writer)
                return
            case "/api/models":
                Task { [weak self] in
                    let payload = await self?.buildModelsPayload() ?? [:]
                    writer.respondJSON(payload)
                }
                return
            case "/api/tests":
                Task { [weak self] in
                    let payload = await self?.buildTestsPayload() ?? [:]
                    writer.respondJSON(payload)
                }
                return
            case "/api/logs":
                handleLogsRoute(writer)
                return
            case "/api/collections":
                Task { [weak self] in
                    let payload = await self?.listCollections() ?? [:]
                    writer.respondJSON(payload)
                }
                return
            case "/api/cascade-docs":
                // Union of every document the caller reaches via
                // collection membership. The /api/snapshot documents
                // list is built from `documents.list()`, which only
                // returns docs with a direct permission grant —
                // cascade-only docs (e.g. shared-collection contents,
                // per-collection refs docs) never appear there. This
                // endpoint fills that gap.
                Task { [weak self] in
                    let payload = await self?.listCascadeDocs() ?? [:]
                    writer.respondJSON(payload)
                }
                return
            case "/api/databases":
                Task { [weak self] in
                    let payload = await self?.listDatabases() ?? [:]
                    writer.respondJSON(payload)
                }
                return
            case "/api/db/operations":
                // List the registered operations for one database. Operations
                // are app-defined (e.g. `listTasks`, `countByStatus`) that
                // wrap CEL-gated queries for regular users — the production
                // path. Coexists with the admin-data path below, which is
                // admin-only and bypasses CEL.
                let databaseId = request.query["databaseId"] ?? ""
                Task { [weak self] in
                    let payload = await self?.listDatabaseOperations(databaseId: databaseId) ?? [:]
                    writer.respondJSON(payload)
                }
                return
            case "/api/db/models":
                // List every model name the DO has recorded state for. The
                // server calls this under `records/models`, which is open to
                // any db member (no CEL gate) — just introspection.
                let databaseId = request.query["databaseId"] ?? ""
                Task { [weak self] in
                    let payload = await self?.listDatabaseModels(databaseId: databaseId) ?? [:]
                    writer.respondJSON(payload)
                }
                return
            case "/api/db/describe":
                // Per-model field descriptor. Powers the "new record" form
                // so the inspector knows what fields to render.
                let databaseId = request.query["databaseId"] ?? ""
                let modelName = request.query["modelName"] ?? ""
                Task { [weak self] in
                    let payload = await self?.describeDatabaseModel(
                        databaseId: databaseId, modelName: modelName
                    ) ?? [:]
                    writer.respondJSON(payload)
                }
                return
            default:
                break
            }
            // Collection-scoped GETs — path-param routes that don't fit the
            // case-literal switch above.
            if path.hasPrefix("/api/collections/") {
                let rest = String(path.dropFirst("/api/collections/".count))
                let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let collectionId = parts[0]
                let suffix = parts.count > 1 ? parts[1] : ""
                if suffix == "documents" {
                    Task { [weak self] in
                        let payload = await self?.listCollectionDocuments(collectionId: collectionId) ?? [:]
                        writer.respondJSON(payload)
                    }
                    return
                }
                if suffix == "access" {
                    Task { [weak self] in
                        let payload = await self?.collectionAccess(collectionId: collectionId) ?? [:]
                        writer.respondJSON(payload)
                    }
                    return
                }
            }
            // Put the rest of the fallthrough from the default case here.
            switch path {
            case "/api/blobs":
                let docId = request.query["documentId"] ?? ""
                Task { [weak self] in
                    let payload = await self?.listBlobs(documentId: docId) ?? []
                    writer.respondJSON(payload)
                }
                return
            case "/api/sqlite/diag":
                // Diagnostic payload so a "blank SQLite tab" is self-debugging:
                // the UI can report whether we failed at "no roots", "no
                // matching namespace dir", or "file missing under the dir".
                writer.respondJSON(sqliteDiagnostic())
                return
            case "/api/memdb":
                // Catalog of in-memory SQL projections, one per inspectable
                // model that surfaced an `InspectableMemoryDB`. The query
                // engine lives entirely in RAM (`:memory:` SQLite) so this
                // is the only way to see what the engine actually has.
                Task { [weak self] in
                    let payload = await self?.buildMemDBPayload() ?? ["models": []]
                    writer.respondJSON(payload)
                }
                return
            case "/api/memdb/columns":
                let model = request.query["model"] ?? ""
                let docId = request.query["documentId"] ?? ""
                let table = request.query["table"] ?? ""
                Task { [weak self] in
                    let cols = await self?.memDBColumns(model: model, documentId: docId, table: table) ?? []
                    writer.respondJSON(cols)
                }
                return
            case "/api/memdb/rows":
                let model = request.query["model"] ?? ""
                let docId = request.query["documentId"] ?? ""
                let table = request.query["table"] ?? ""
                let limit = Int(request.query["limit"] ?? "200") ?? 200
                Task { [weak self] in
                    let rows = await self?.memDBRows(model: model, documentId: docId, table: table, limit: limit) ?? []
                    writer.respondJSON(rows)
                }
                return
            case "/api/blob/content":
                // Stream the raw blob bytes through so <img src> / download
                // links work directly against the inspector. Content-Type
                // comes from the blob's metadata; `?download=1` adds a
                // Content-Disposition: attachment header so browsers save
                // instead of render.
                let docId = request.query["documentId"] ?? ""
                let blobId = request.query["blobId"] ?? ""
                let asDownload = request.query["download"] == "1"
                Task { [weak self] in
                    await self?.serveBlobContent(
                        documentId: docId, blobId: blobId,
                        asDownload: asDownload, writer: writer
                    )
                }
                return
            case "/api/doc/permissions":
                let docId = request.query["documentId"] ?? ""
                Task { [weak self] in
                    let payload = await self?.docPermissions(documentId: docId) ?? [:]
                    writer.respondJSON(payload)
                }
                return
            default:
                if path.hasPrefix("/api/sqlite/store/") {
                    let name = String(path.dropFirst("/api/sqlite/store/".count))
                    let limit = Int(request.query["limit"] ?? "100") ?? 100
                    let offset = Int(request.query["offset"] ?? "0") ?? 0
                    let rows = sqlite?.readStore(name, limit: limit, offset: offset) ?? []
                    let json = rows.map { r -> [String: Any] in
                        var d: [String: Any] = ["key": r.key, "value": r.value]
                        if let md = r.metadata { d["metadata"] = md }
                        if let ts = r.updatedAt { d["updatedAt"] = ts }
                        return d
                    }
                    writer.respondJSON(json)
                    return
                }
                if path.hasPrefix("/api/models/") {
                    let name = String(path.dropFirst("/api/models/".count))
                    let docId = request.query["documentId"] ?? ""
                    Task { [weak self] in
                        do {
                            let rows = try await self?.loadModelRecords(modelName: name, documentId: docId) ?? []
                            writer.respondJSON(rows)
                        } catch {
                            inspectorLog("model load failed: \(name): \(error)", level: "warn")
                            writer.respondJSON(["error": String(describing: error)], status: 500)
                        }
                    }
                    return
                }
                // Host-registered custom routes. Last in the chain so
                // built-in routes always win on collision.
                Task { [weak self] in
                    guard let self else {
                        writer.notFound()
                        return
                    }
                    let result = await self.tryCustomRoute(path: path, query: request.query)
                    switch result {
                    case .matched(let body):
                        writer.respondJSON(body)
                    case .notMatched:
                        inspectorLog("404: GET \(path)", level: "warn")
                        writer.notFound()
                    }
                }
                return
            }
        }
        // Write endpoints — `/api/action/*` funnels every mutation through a single dispatcher
        // so we can keep them all on the main actor and share error handling.
        if request.method == "POST", path.hasPrefix("/api/action/") {
            let action = String(path.dropFirst("/api/action/".count))
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            Task { [weak self] in
                let result = await self?.dispatchAction(action, body: body)
                    ?? ["ok": false, "error": "inspector gone"]
                writer.respondJSON(result)
            }
            return
        }
        // Any miss falls here. Logged so unexpected 404s are diagnosable from the Logs tab —
        // most often it's a stale cached HTML referencing an endpoint we've since renamed.
        inspectorLog("404: \(request.method) \(path)", level: "warn")
        writer.notFound()
    }

    private func handleLogsRoute(_ writer: ResponseWriter) {
        writer.respondJSON(["lines": InspectorLog.shared.snapshot()])
    }

    private func handleEventsStream(_ writer: ResponseWriter) {
        let channel = writer.startSSE()
        lock.lock()
        let snapshot = events
        sseChannels.append(channel)
        sseChannels.removeAll { $0.isClosed }
        lock.unlock()
        if !snapshot.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: snapshot),
           let json = String(data: data, encoding: .utf8) {
            channel.sendEvent(name: "init", jsonData: json)
        }
    }

    // MARK: - Actions

    /// Every UI-triggered mutation flows through here. Returns a JSON-ready dict with at
    /// least `{ ok: Bool }` and optional fields the caller cares about (e.g. new doc id).
    @MainActor
    private func dispatchAction(_ action: String, body: [String: Any]) async -> [String: Any] {
        inspectorLog("action \(action) body=\(body)")
        guard let client else {
            inspectorLog("action \(action) → no client", level: "error")
            return ["ok": false, "error": "no client"]
        }
        do {
            switch action {
            case "doc/create":
                // DocumentsAPI.create delegates to the local-first
                // JsBaoClient.createDocument (js-bao-wss#1108): a ULID is minted
                // client-side, the doc is writable immediately, and the server
                // commit happens in the background.
                var opts = CreateDocumentOptions()
                if let title = body["title"] as? String, !title.isEmpty { opts.title = title }
                if let tags = body["tags"] as? [String] { opts.tags = tags }
                let result = try await client.documents.create(options: opts)
                let id = result.metadata?.objectValue?["documentId"]?.stringValue ?? ""
                appState?.addSyncMessage("Inspector: created \(id.prefix(12))…")
                await appState?.fetchDocuments()
                return ["ok": true, "documentId": id]
            case "doc/delete":
                guard let id = body["documentId"] as? String else { return ["ok": false, "error": "documentId required"] }
                _ = try await client.documents.delete(documentId: id)
                await appState?.fetchDocuments()
                return ["ok": true]
            case "doc/rename":
                guard let id = body["documentId"] as? String,
                      let title = body["title"] as? String else { return ["ok": false, "error": "documentId + title required"] }
                _ = try await client.documents.update(documentId: id, data: UpdateDocumentData(title: title))
                await appState?.fetchDocuments()
                return ["ok": true]
            case "doc/close":
                guard let id = body["documentId"] as? String else { return ["ok": false, "error": "documentId required"] }
                await client.closeDocument(id)
                return ["ok": true]
            case "doc/open":
                // Await the full open + sync + post-open hook so the UI's
                // follow-up /api/models fetch sees the rebound models for
                // the newly-opened doc — otherwise the Records tab would
                // show stale models from whatever doc was previously active.
                guard let id = body["documentId"] as? String else { return ["ok": false, "error": "documentId required"] }
                await appState?.selectDocumentAwaiting(id)
                return ["ok": true, "documentId": id]
            case "doc/share":
                guard let id = body["documentId"] as? String,
                      let email = body["email"] as? String else { return ["ok": false, "error": "documentId + email required"] }
                let permission = (body["permission"] as? String) ?? "read-write"
                // Migrated off the deprecated `sendInvitation` to `updatePermissions`
                // (the deferred-grant flow), per the js-bao deprecation guidance.
                _ = try await client.documents.updatePermissions(
                    documentId: id,
                    params: .email(email, permission: permission, sendEmail: true)
                )
                return ["ok": true]
            case "doc/setPermission":
                // Update an already-accepted user's permission on a document
                // (e.g. flip Reader → Editor). Distinct from `doc/share`,
                // which always sends a fresh invitation.
                guard let id = body["documentId"] as? String,
                      let userId = body["userId"] as? String,
                      let permission = body["permission"] as? String else {
                    return ["ok": false, "error": "documentId + userId + permission required"]
                }
                _ = try await client.documents.updatePermissions(
                    documentId: id,
                    params: .user(userId, permission: permission)
                )
                return ["ok": true]
            case "doc/revokePermission":
                // Remove a user's direct permission on a document. Cascade
                // permissions (via shared collections) are unaffected.
                guard let id = body["documentId"] as? String,
                      let userId = body["userId"] as? String else {
                    return ["ok": false, "error": "documentId + userId required"]
                }
                _ = try await client.documents.removePermission(documentId: id, .userId(userId))
                return ["ok": true]
            case "db/create":
                // Minimum server contract is just `title`; `databaseType`
                // defaults to `"default"` when the caller doesn't pick one.
                guard let title = (body["title"] as? String), !title.isEmpty else {
                    return ["ok": false, "error": "title required"]
                }
                let dbType = (body["databaseType"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
                let result = try await client.databases.create(
                    params: CreateDatabaseParams(title: title, databaseType: dbType)
                )
                return ["ok": true, "databaseId": result.databaseId, "result": result.inspectorDict]
            case "db/rename":
                guard let id = body["databaseId"] as? String,
                      let title = body["title"] as? String else { return ["ok": false, "error": "databaseId + title required"] }
                _ = try await client.databases.update(databaseId: id, params: UpdateDatabaseParams(title: title))
                return ["ok": true]
            case "db/delete":
                guard let id = body["databaseId"] as? String else { return ["ok": false, "error": "databaseId required"] }
                _ = try await client.databases.delete(databaseId: id)
                return ["ok": true]
            case "col/create":
                guard let name = body["name"] as? String, !name.isEmpty else {
                    return ["ok": false, "error": "name required"]
                }
                let result = try await client.collections.create(params: CreateCollectionParams(name: name))
                return ["ok": true, "collectionId": result.collectionId, "result": result.inspectorDict]
            case "col/rename":
                guard let id = body["collectionId"] as? String,
                      let name = body["name"] as? String else { return ["ok": false, "error": "collectionId + name required"] }
                _ = try await client.collections.update(collectionId: id, params: UpdateCollectionParams(name: name))
                return ["ok": true]
            case "col/delete":
                guard let id = body["collectionId"] as? String else { return ["ok": false, "error": "collectionId required"] }
                _ = try await client.collections.delete(collectionId: id)
                return ["ok": true]
            case "col/addDoc":
                guard let cid = body["collectionId"] as? String,
                      let did = body["documentId"] as? String else { return ["ok": false, "error": "collectionId + documentId required"] }
                _ = try await client.collections.addDocument(collectionId: cid, documentId: did)
                return ["ok": true]
            case "col/removeDoc":
                guard let cid = body["collectionId"] as? String,
                      let did = body["documentId"] as? String else { return ["ok": false, "error": "collectionId + documentId required"] }
                _ = try await client.collections.removeDocument(collectionId: cid, documentId: did)
                return ["ok": true]
            case "col/grant":
                guard let cid = body["collectionId"] as? String,
                      let groupType = body["groupType"] as? String,
                      let groupId = body["groupId"] as? String else {
                    return ["ok": false, "error": "collectionId + groupType + groupId required"]
                }
                let permission = (body["permission"] as? String) ?? "reader"
                _ = try await client.collections.grantGroupPermission(
                    collectionId: cid,
                    params: GrantCollectionGroupPermissionParams(
                        groupType: groupType, groupId: groupId, permission: permission
                    )
                )
                return ["ok": true]
            case "col/revoke":
                guard let cid = body["collectionId"] as? String,
                      let groupType = body["groupType"] as? String,
                      let groupId = body["groupId"] as? String else {
                    return ["ok": false, "error": "collectionId + groupType + groupId required"]
                }
                _ = try await client.collections.revokeGroupPermission(collectionId: cid, groupType: groupType, groupId: groupId)
                return ["ok": true]
            case "col/addMember":
                guard let cid = body["collectionId"] as? String,
                      let userId = body["userId"] as? String else {
                    return ["ok": false, "error": "collectionId + userId required"]
                }
                let permission = (body["permission"] as? String)
                    .flatMap { CollectionPermission(rawValue: $0) } ?? .reader
                _ = try await client.collections.addMember(
                    collectionId: cid,
                    params: .user(userId, permission: permission)
                )
                return ["ok": true]
            case "col/removeMember":
                guard let cid = body["collectionId"] as? String,
                      let userId = body["userId"] as? String else {
                    return ["ok": false, "error": "collectionId + userId required"]
                }
                _ = try await client.collections.removeMember(collectionId: cid, userId: userId)
                return ["ok": true]
            case "db/records/query":
                // Generic "list rows in a model" path. Requires app admin +
                // db owner permissions server-side (admin-data is the
                // debugging door, not the production one). 403s come back
                // through the existing HttpError catch block with the
                // server's explanation.
                guard let id = body["databaseId"] as? String,
                      let modelName = body["modelName"] as? String else {
                    return ["ok": false, "error": "databaseId + modelName required"]
                }
                var payload: [String: Any] = ["modelName": modelName]
                if let filter = body["filter"] as? [String: Any] { payload["filter"] = filter }
                if let options = body["options"] as? [String: Any] { payload["options"] = options }
                let raw = try await client.makeRequest(
                    "POST", "/databases/\(id)/admin-data/query", payload
                )
                // DO response shape: { data: [...], hasMore, cursors? }
                var rows: [[String: Any]] = []
                if let dict = raw as? [String: Any], let d = dict["data"] as? [[String: Any]] {
                    rows = d
                } else if let arr = raw as? [[String: Any]] {
                    rows = arr
                }
                return ["ok": true, "rows": rows, "result": raw]
            case "db/records/create":
                guard let id = body["databaseId"] as? String,
                      let modelName = body["modelName"] as? String,
                      let data = body["data"] as? [String: Any] else {
                    return ["ok": false, "error": "databaseId + modelName + data required"]
                }
                // Server requires either `id` or `upsertOn`. For the
                // inspector we always generate a client-side ULID when the
                // caller didn't supply one so the happy path doesn't require
                // the user to know about unique indexes.
                let recordId = (body["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? generateULID()
                var payload: [String: Any] = [
                    "modelName": modelName,
                    "id": recordId,
                    "data": data,
                ]
                if let stringSets = body["stringSets"] as? [String: Any] {
                    payload["stringSets"] = stringSets
                }
                _ = try await client.makeRequest(
                    "POST", "/databases/\(id)/admin-data/save", payload
                )
                return ["ok": true, "id": recordId]
            case "db/records/delete":
                guard let id = body["databaseId"] as? String,
                      let modelName = body["modelName"] as? String,
                      let recordId = body["id"] as? String else {
                    return ["ok": false, "error": "databaseId + modelName + id required"]
                }
                _ = try await client.makeRequest(
                    "POST", "/databases/\(id)/admin-data/delete",
                    ["modelName": modelName, "id": recordId]
                )
                return ["ok": true]
            case "db/records/patch":
                guard let id = body["databaseId"] as? String,
                      let modelName = body["modelName"] as? String,
                      let recordId = body["id"] as? String,
                      let data = body["data"] as? [String: Any] else {
                    return ["ok": false, "error": "databaseId + modelName + id + data required"]
                }
                _ = try await client.makeRequest(
                    "POST", "/databases/\(id)/admin-data/patch",
                    ["modelName": modelName, "id": recordId, "data": data]
                )
                return ["ok": true]
            case "db/execute":
                // Run one named operation against a database and return its
                // raw result. Operations are defined app-side on the server
                // (via registerOperation) — the inspector doesn't know which
                // are safe to re-run, which mutate, or what options they
                // take; we just pass through and let the caller figure out.
                guard let id = body["databaseId"] as? String,
                      let name = body["name"] as? String else {
                    return ["ok": false, "error": "databaseId + name required"]
                }
                var options: ExecuteOperationOptions?
                if let o = body["options"] as? [String: Any], !o.isEmpty {
                    options = ExecuteOperationOptions(
                        params: inspectorJSONValue(from: o["params"]),
                        limit: o["limit"] as? Int,
                        cursor: o["cursor"] as? String,
                        timing: o["timing"] as? Bool
                    )
                }
                // `executeOperation` now returns a typed `JSONValue`; project it
                // back to a JSONSerialization-safe `Any` for the UI.
                let raw = inspectorAny(try await client.databases.executeOperation(
                    databaseId: id, name: name, options: options
                ))
                // Normalize the common "returns rows" shape ({ data: [...] })
                // vs "returns an array" vs "returns a scalar". The UI renders
                // `rows` as a table when present; otherwise it falls back to
                // the raw value under `result`.
                var rows: [[String: Any]] = []
                if let dict = raw as? [String: Any], let d = dict["data"] as? [[String: Any]] {
                    rows = d
                } else if let arr = raw as? [[String: Any]] {
                    rows = arr
                }
                return ["ok": true, "rows": rows, "result": raw]
            case "record/delete":
                guard let modelName = body["model"] as? String,
                      let docId = body["documentId"] as? String,
                      let id = body["id"] as? String else { return ["ok": false, "error": "model + documentId + id required"] }
                guard let entry = inspectableModel(name: modelName, documentId: docId) else {
                    return ["ok": false, "error": "unknown model"]
                }
                guard let delete = entry.deleteById else {
                    return ["ok": false, "error": "model is read-only"]
                }
                delete(id)
                return ["ok": true]
            case "record/create":
                guard let modelName = body["model"] as? String,
                      let docId = body["documentId"] as? String,
                      let values = body["values"] as? [String: Any] else {
                    return ["ok": false, "error": "model + documentId + values required"]
                }
                guard let entry = inspectableModel(name: modelName, documentId: docId) else {
                    return ["ok": false, "error": "unknown model"]
                }
                guard let create = entry.createWith else {
                    return ["ok": false, "error": "model doesn't support create from the inspector"]
                }
                do {
                    let id = try create(values)
                    return ["ok": true, "id": id]
                } catch {
                    return ["ok": false, "error": String(describing: error)]
                }
            case "test/run":
                guard let id = body["id"] as? String else { return ["ok": false, "error": "id required"] }
                return await runTest(id: id)
            case "blob/delete":
                guard let docId = body["documentId"] as? String,
                      let blobId = body["blobId"] as? String else { return ["ok": false, "error": "documentId + blobId required"] }
                _ = try await client.documents.blobs(documentId: docId).delete(blobId: blobId)
                return ["ok": true]
            case "blob/upload":
                // Accept the payload as base64 so we don't have to teach
                // DebugHTTPServer multipart parsing. The UI FileReader reads
                // the file as an ArrayBuffer then base64-encodes it before
                // POSTing.
                guard let docId = body["documentId"] as? String,
                      let dataB64 = body["data"] as? String,
                      let data = Data(base64Encoded: dataB64) else {
                    return ["ok": false, "error": "documentId + data (base64) required"]
                }
                var opts = BlobUploadSourceOptions()
                if let filename = body["filename"] as? String, !filename.isEmpty {
                    opts.filename = filename
                }
                if let contentType = body["contentType"] as? String, !contentType.isEmpty {
                    opts.contentType = contentType
                }
                let result = try await client.documents.blobs(documentId: docId).upload(
                    data: data, options: opts
                )
                return [
                    "ok": true,
                    "blobId": result.blobId,
                    "numBytes": result.numBytes,
                    "contentType": result.contentType,
                ]
            case "memdb/exec":
                // Run an arbitrary read-only SQL against the model's in-memory
                // query engine. We refuse anything that isn't SELECT or PRAGMA
                // because direct DML/DDL would desync the engine projection
                // from its Y.Doc source of truth — and the next observer-driven
                // sync would clobber the changes anyway, so even "successful"
                // writes would be misleading.
                guard let modelName = body["model"] as? String,
                      let docId = body["documentId"] as? String,
                      let sql = body["sql"] as? String else {
                    return ["ok": false, "error": "model + documentId + sql required"]
                }
                guard let entry = inspectableModel(name: modelName, documentId: docId),
                      let mdb = entry.memoryDB else {
                    return ["ok": false, "error": "unknown model or no memory DB"]
                }
                let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
                let firstWord = trimmed
                    .split(whereSeparator: { $0.isWhitespace || $0 == "(" })
                    .first.map { String($0).uppercased() } ?? ""
                guard firstWord == "SELECT" || firstWord == "PRAGMA" || firstWord == "WITH" else {
                    return [
                        "ok": false,
                        "error": "only SELECT / PRAGMA / WITH allowed — direct DML against the engine would desync from the Y.Doc. " +
                                 "Use the row controls or the Documents tab for create/delete.",
                    ]
                }
                let rows = mdb.executeQuery(trimmed)
                // SQLite hands us rows as Swift dicts, which lose column order
                // (Dictionary iteration is unordered). For a debug tool that's
                // tolerable — sort alphabetically with `id` pinned first so the
                // primary key is always leftmost. Users wanting explicit column
                // order can write `SELECT id, title, ...` and we'll preserve
                // those names; the layout just won't preserve their order.
                let allKeys = Set(rows.flatMap { Array($0.keys) })
                let columns: [String] = allKeys.sorted { lhs, rhs in
                    if lhs == "id" { return true }
                    if rhs == "id" { return false }
                    if lhs == "_meta_doc_id" { return rhs != "id" }
                    if rhs == "_meta_doc_id" { return lhs == "id" }
                    return lhs < rhs
                }
                return ["ok": true, "rows": rows, "columns": columns]
            default:
                // Fall through to host-registered custom actions. Built-ins
                // above always take precedence on name collision.
                if let host = appState as? InspectorActionHost,
                   let custom = host.inspectorActions.first(where: { $0.name == action }) {
                    let result = try await custom.handler(body)
                    // Wrap in `ok: true` if the handler didn't already say
                    // otherwise; respect explicit `ok: false` from the handler
                    // (lets handlers signal validation failures cleanly).
                    if result["ok"] != nil {
                        return result
                    }
                    var wrapped = result
                    wrapped["ok"] = true
                    return wrapped
                }
                inspectorLog("action \(action) → unknown", level: "warn")
                return ["ok": false, "error": "unknown action \(action)"]
            }
        } catch let http as HttpError {
            // HttpError.body contains the server's actual explanation for 400/403/etc.
            // Surface it to the UI so the dev doesn't have to guess why the server said no.
            inspectorLog("action \(action) → HTTP \(http.status): \(http.message) · body=\(http.body ?? "")", level: "error")
            return [
                "ok": false,
                "error": http.message,
                "status": http.status,
                "serverBody": http.body ?? "",
            ]
        } catch let err as JsBaoError {
            inspectorLog("action \(action) → JsBao \(err.code.rawValue): \(err.message)", level: "error")
            return [
                "ok": false,
                "error": err.message,
                "code": err.code.rawValue,
                "details": err.details ?? [:],
            ]
        } catch let err as AuthError {
            inspectorLog("action \(action) → Auth \(err.code?.rawValue ?? "?"): \(err.message)", level: "error")
            return [
                "ok": false,
                "error": err.message,
                "code": err.code?.rawValue ?? "AUTH",
            ]
        } catch {
            // Fall-through for Swift errors that don't carry structured fields. Use
            // String(describing:) — richer than `localizedDescription` for most Error types.
            inspectorLog("action \(action) → \(error)", level: "error")
            return ["ok": false, "error": String(describing: error)]
        }
    }

    // MARK: - Custom routes

    private enum CustomRouteResult {
        case matched(Any)
        case notMatched
    }

    /// Look up a host-registered `InspectorRoute` matching `path` and invoke its handler.
    /// Returns `.notMatched` if no route is registered for the path so the caller can 404.
    /// All errors thrown by the handler are caught and surfaced in the JSON body.
    @MainActor
    private func tryCustomRoute(path: String, query: [String: String]) async -> CustomRouteResult {
        guard let host = appState as? InspectorRouteHost else { return .notMatched }
        guard let route = host.inspectorRoutes.first(where: { $0.path == path }) else {
            return .notMatched
        }
        do {
            let result = try await route.handler(query)
            return .matched(result)
        } catch let http as HttpError {
            inspectorLog("route \(path) → HTTP \(http.status): \(http.message)", level: "error")
            return .matched([
                "ok": false,
                "error": http.message,
                "status": http.status,
                "serverBody": http.body ?? "",
            ] as [String: Any])
        } catch {
            inspectorLog("route \(path) → \(error)", level: "error")
            return .matched(["ok": false, "error": String(describing: error)] as [String: Any])
        }
    }

    // MARK: - Snapshot

    @MainActor
    private func buildSnapshot() async -> [String: Any] {
        guard let client, let appConfig else { return [:] }

        let connection: [String: Any] = [
            "isConnected": client.isConnected,
            "connectionId": client.connectionId,
            "apiUrl": client.getApiUrl(),
            "wsUrl": appConfig.wsUrl,
            "appId": client.getAppId(),
            "globalAdminAppId": client.getGlobalAdminAppId(),
        ]

        let user: [String: Any] = [
            "name": appState?.userName ?? "",
            "email": appState?.userEmail ?? "",
        ]

        let openIds = Set(client.listOpenDocuments())
        let pendingIds = Set(client.listPendingCreates())
        let serverDocs = appState?.documents ?? []

        var merged: [String: [String: Any]] = [:]
        for info in serverDocs {
            merged[info.id] = docEntry(
                id: info.id, title: info.title, permission: info.permission,
                isOpen: openIds.contains(info.id), client: client,
                isPendingCreate: pendingIds.contains(info.id)
            )
        }
        for id in openIds where merged[id] == nil {
            merged[id] = docEntry(
                id: id, title: nil, permission: nil,
                isOpen: true, client: client,
                isPendingCreate: pendingIds.contains(id)
            )
        }
        for id in pendingIds where merged[id] == nil {
            merged[id] = docEntry(
                id: id, title: nil, permission: nil,
                isOpen: openIds.contains(id), client: client,
                isPendingCreate: true
            )
        }
        let documents: [[String: Any]] = Array(merged.values)

        let storage: [String: Any] = {
            guard let sqlite else { return ["path": NSNull(), "stores": []] }
            let path = sqlite.resolveDatabasePath() ?? ""
            let stores = sqlite.listStores().map { [
                "name": $0.name,
                "rowCount": $0.rowCount,
            ] }
            return [
                "path": path.isEmpty ? NSNull() : path,
                "stores": stores,
            ]
        }()

        return [
            "connection": connection,
            "user": user,
            "documents": documents,
            "storage": storage,
            "selectedDocId": appState?.selectedDocId ?? NSNull(),
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
    }

    private func docEntry(
        id: String, title: String?, permission: String?,
        isOpen: Bool, client: JsBaoClient, isPendingCreate: Bool
    ) -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "isOpen": isOpen,
            "isPendingCreate": isPendingCreate,
        ]
        if let title { d["title"] = title }
        if let permission { d["permission"] = permission }
        if isOpen {
            d["isSynced"] = client.isSynced(id)
            d["isReadOnly"] = client.isDocumentReadOnly(id)
        }
        d["isLocalOnly"] = client.isLocalOnly(id)
        d["hasLocalCopy"] = client.hasLocalCopy(id)
        return d
    }

    // MARK: - Models

    @MainActor
    private func buildModelsPayload() async -> [String: Any] {
        let entries = appState?.inspectableModels ?? []
        let items: [[String: Any]] = entries.map { m in
            let fields = m.fields.map { f -> [String: Any] in
                ["name": f.name, "kind": f.kind.rawValue, "optional": f.optional]
            }
            return [
                "name": m.name,
                "documentId": m.documentId,
                "fields": fields,
                "readOnly": m.deleteById == nil,
                "canCreate": m.createWith != nil,
            ]
        }
        return ["models": items]
    }

    @MainActor
    private func loadModelRecords(modelName: String, documentId: String) async throws -> [[String: Any]] {
        guard let entry = inspectableModel(name: modelName, documentId: documentId) else { return [] }
        return try entry.loadAll()
    }

    @MainActor
    private func inspectableModel(name: String, documentId: String) -> InspectableModel? {
        return appState?.inspectableModels.first { $0.name == name && $0.documentId == documentId }
    }

    // MARK: - Memory SQL (in-memory query engine)

    /// Catalog payload for the Memory SQL tab. Walks every inspectable model
    /// that surfaces an `InspectableMemoryDB` and lists its tables + row counts.
    /// Each `DynamicModel` owns its own `:memory:` engine, so per-model entries
    /// here are independent SQLite databases — we surface them all flat with the
    /// owning model's name so the UI can group by model.
    @MainActor
    private func buildMemDBPayload() async -> [String: Any] {
        let entries = appState?.inspectableModels ?? []
        let items: [[String: Any]] = entries.compactMap { m in
            guard let mdb = m.memoryDB else { return nil }
            let tables = mdb.listTables().map { name -> [String: Any] in
                ["name": name, "rowCount": mdb.rowCount(name)]
            }
            return [
                "model": m.name,
                "documentId": m.documentId,
                "mainTable": mdb.tableName,
                "tables": tables,
            ]
        }
        return ["models": items]
    }

    @MainActor
    private func memDBColumns(model: String, documentId: String, table: String) async -> [[String: Any]] {
        guard let entry = inspectableModel(name: model, documentId: documentId),
              let mdb = entry.memoryDB else { return [] }
        return mdb.columns(table).map { c in
            ["name": c.name, "type": c.type, "notNull": c.notNull, "pk": c.isPrimaryKey]
        }
    }

    @MainActor
    private func memDBRows(model: String, documentId: String, table: String, limit: Int) async -> [[String: Any]] {
        guard let entry = inspectableModel(name: model, documentId: documentId),
              let mdb = entry.memoryDB else { return [] }
        return mdb.rows(table, limit)
    }

    // MARK: - Tests

    @MainActor
    private func buildTestsPayload() async -> [String: Any] {
        let host = appState as? InspectorTestHost
        let tests = host?.inspectorTests ?? []
        // Hide `.headless`-only tests: they need the CI runner's bootstrapped,
        // authenticated client and aren't meaningful in the in-app panel.
        // Mirrors the JS browser panel skipping `"node"` tests (TestRunner.vue).
        let items: [[String: Any]] = tests
            .filter { $0.environment != .headless }
            .map { t in ["id": t.id, "group": t.group, "name": t.name] }
        return ["tests": items]
    }

    /// Runs a single registered test. `id` is `group::name` from `InspectorTest.id`. Captures
    /// logs + thrown errors so the UI can render pass/fail + output without a separate SSE
    /// stream — keeps the action contract uniform (single JSON response per action).
    @MainActor
    private func runTest(id: String) async -> [String: Any] {
        let parts = id.components(separatedBy: "::")
        guard parts.count == 2 else { return ["ok": false, "error": "bad test id"] }
        let (group, name) = (parts[0], parts[1])
        let host = appState as? InspectorTestHost
        guard let test = host?.inspectorTests.first(where: { $0.group == group && $0.name == name }) else {
            return ["ok": false, "error": "test not found: \(id)"]
        }
        // `.headless`-only tests are hidden from the panel list; refuse if one
        // is invoked directly (e.g. a stale cached UI) rather than run it in a
        // context it wasn't written for.
        if test.environment == .headless {
            return ["ok": false, "error": "test \(id) is headless-only — run it via the CI runner (PrimitiveAppTesting)"]
        }
        let ctx = TestContext()
        let started = Date()
        var passed = true
        var failureMessage: String?
        do {
            try await test.run(ctx)
        } catch {
            passed = false
            if let fail = error as? TestFailure {
                failureMessage = fail.message
            } else {
                failureMessage = (error as CustomStringConvertible).description
            }
        }
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        return [
            "ok": true,
            "id": id,
            "passed": passed,
            "durationMs": durationMs,
            "output": ctx.output,
            "error": failureMessage ?? "",
        ]
    }

    // MARK: - Collections / Blobs / Databases / ACL

    @MainActor
    private func listCollections() async -> [String: Any] {
        guard let client else { return [:] }
        do {
            let res = try await client.collections.list(options: PaginationOptions(limit: 100))
            return ["items": res.items.map { $0.inspectorDict }]
        } catch {
            return ["items": [], "error": error.localizedDescription]
        }
    }

    /// Build the cascade-docs list: documents reachable to the caller
    /// ONLY via collection membership — docs the user already has a
    /// direct permission grant on (owner, directly-shared) are
    /// excluded since they show up in the regular Documents section
    /// already. Without this filter, every refs doc the user
    /// themselves created appeared in BOTH sections, which was
    /// confusing. Each remaining entry carries `collectionIds:
    /// [String]` so the UI can show which collections gave the
    /// cascade access.
    private func listCascadeDocs() async -> [String: Any] {
        guard let client else { return ["items": []] }

        // 1. Fetch the user's direct-grant doc set so we can subtract
        //    it. The owned + shared union (migrated off the deprecated
        //    `documents.list`) is anything with a row in the user's
        //    permission table — exactly the "non-cascade" set.
        var directDocIds = Set<String>()
        do {
            // Owned + shared union, composed inline (the client exposes only
            // `ownedDocuments` / `sharedDocuments`).
            async let ownedTask = client.me.ownedDocuments(limit: 500)
            async let sharedTask = client.me.sharedDocuments(limit: 500)
            for info in try await ownedTask where !info.documentId.isEmpty {
                directDocIds.insert(info.documentId)
            }
            for share in try await sharedTask.items where !share.document.documentId.isEmpty {
                directDocIds.insert(share.document.documentId)
            }
        } catch {
            // If the list call fails, fall through with an empty set
            // — we'll over-include rather than hide a doc.
        }

        // 2. Fetch every collection's member docs in parallel.
        let collections: [CollectionInfo]
        do {
            collections = try await client.collections.list(options: PaginationOptions(limit: 100)).items
        } catch {
            return ["items": [], "error": error.localizedDescription]
        }

        // docId → merged entry (title, tags, [collectionIds])
        var byDocId: [String: [String: Any]] = [:]

        await withTaskGroup(of: (String, [CollectionDocumentInfo]).self) { group in
            for c in collections {
                let cid = c.collectionId
                guard !cid.isEmpty else { continue }
                group.addTask { [weak self] in
                    guard let self, let client = self.client else { return (cid, []) }
                    do {
                        let resp = try await client.collections.listDocuments(
                            collectionId: cid,
                            options: PaginationOptions(limit: 200)
                        )
                        return (cid, resp.items)
                    } catch {
                        return (cid, [])
                    }
                }
            }
            for await (cid, items) in group {
                for item in items {
                    let docId = item.documentId
                    guard !docId.isEmpty else { continue }
                    // Skip docs the user has direct access to — they
                    // belong in the regular Documents section.
                    if directDocIds.contains(docId) { continue }
                    if var existing = byDocId[docId] {
                        var cids = (existing["collectionIds"] as? [String]) ?? []
                        if !cids.contains(cid) { cids.append(cid) }
                        existing["collectionIds"] = cids
                        byDocId[docId] = existing
                    } else {
                        byDocId[docId] = [
                            "id": docId,
                            "title": item.title ?? "",
                            "tags": item.tags ?? [],
                            "permission": item.permission?.rawValue ?? "",
                            "collectionIds": [cid],
                        ]
                    }
                }
            }
        }

        let items = Array(byDocId.values).sorted { lhs, rhs in
            (lhs["title"] as? String ?? "") < (rhs["title"] as? String ?? "")
        }
        return ["items": items]
    }

    private func sqliteDiagnostic() -> [String: Any] {
        guard let sqlite else { return ["error": "sqlite reader not initialized"] }
        let diag = sqlite.resolve()
        let isoFormatter = ISO8601DateFormatter()
        let candidates: [[String: Any]] = diag.candidates.map { (root, subs) in
            let subdirs: [[String: Any]] = subs.map { (name, mtime) in
                [
                    "name": name,
                    "mtime": isoFormatter.string(from: mtime),
                ]
            }
            return ["root": root, "subdirs": subdirs]
        }
        var payload: [String: Any] = [
            "appId": diag.appId,
            "candidateRoots": diag.candidateRoots,
            "candidates": candidates,
            "resolvedPath": diag.path ?? NSNull(),
        ]
        if let probe = diag.probe {
            // Explicit `Any` so the dict literal doesn't try to unify
            // `Int?` / `String?` with `NSNull` at its element type.
            var probeDict: [String: Any] = [
                "tables": probe.tables,
            ]
            probeDict["fileSize"]            = probe.fileSize.map            { $0 as Any } ?? NSNull()
            probeDict["walFileSize"]         = probe.walFileSize.map         { $0 as Any } ?? NSNull()
            probeDict["shmFileSize"]         = probe.shmFileSize.map         { $0 as Any } ?? NSNull()
            probeDict["openError"]           = probe.openError.map           { $0 as Any } ?? NSNull()
            probeDict["journalMode"]         = probe.journalMode.map         { $0 as Any } ?? NSNull()
            probeDict["kvStoreRowsPre"]      = probe.kvStoreRowsPre.map      { $0 as Any } ?? NSNull()
            probeDict["kvStoreRowsPost"]     = probe.kvStoreRowsPost.map     { $0 as Any } ?? NSNull()
            probeDict["walCheckpointResult"] = probe.walCheckpointResult.map { $0 as Any } ?? NSNull()
            payload["probe"] = probeDict
        }
        return payload
    }

    @MainActor
    private func listDatabases() async -> [String: Any] {
        guard let client else { return [:] }
        do {
            let items = try await client.databases.list()
            return ["items": items.map { $0.inspectorDict }]
        } catch {
            return ["items": [], "error": error.localizedDescription]
        }
    }

    @MainActor
    private func listDatabaseOperations(databaseId: String) async -> [String: Any] {
        guard let client, !databaseId.isEmpty else { return [:] }
        do {
            let items = try await client.databases.listOperations(databaseId: databaseId)
            return ["items": items.map { $0.inspectorDict }]
        } catch {
            return ["items": [], "error": error.localizedDescription]
        }
    }

    @MainActor
    private func listDatabaseModels(databaseId: String) async -> [String: Any] {
        guard let client, !databaseId.isEmpty else { return [:] }
        do {
            let raw = try await client.makeRequest(
                "GET", "/databases/\(databaseId)/records/models", nil
            )
            // DO shape: `{ models: ["name", ...] }`.
            if let dict = raw as? [String: Any], let models = dict["models"] as? [String] {
                return ["models": models]
            }
            return ["models": [] as [String]]
        } catch {
            return ["models": [] as [String], "error": error.localizedDescription]
        }
    }

    @MainActor
    private func describeDatabaseModel(databaseId: String, modelName: String) async -> [String: Any] {
        guard let client, !databaseId.isEmpty, !modelName.isEmpty else { return [:] }
        do {
            let fields = try await client.databases.describe(
                databaseId: databaseId, modelName: modelName
            )
            return ["fields": fields.map { $0.inspectorDict }]
        } catch {
            return ["fields": [] as [[String: Any]], "error": error.localizedDescription]
        }
    }

    @MainActor
    private func listCollectionDocuments(collectionId: String) async -> [String: Any] {
        guard let client, !collectionId.isEmpty else { return [:] }
        do {
            let res = try await client.collections.listDocuments(
                collectionId: collectionId,
                options: PaginationOptions(limit: 100)
            )
            return ["items": res.items.map { $0.inspectorDict }]
        } catch {
            return ["items": [], "error": error.localizedDescription]
        }
    }

    @MainActor
    private func collectionAccess(collectionId: String) async -> [String: Any] {
        guard let client, !collectionId.isEmpty else { return [:] }
        do {
            let access = try await client.collections.getAccess(collectionId: collectionId)
            return ["access": access.inspectorDict]
        } catch {
            return ["access": [:], "error": error.localizedDescription]
        }
    }

    @MainActor
    private func listBlobs(documentId: String) async -> [[String: Any]] {
        guard let client, !documentId.isEmpty else { return [] }
        do {
            return try await client.documents.blobs(documentId: documentId).list(limit: 100)
                .items.map { $0.inspectorDict }
        } catch {
            return []
        }
    }

    /// Respond with the raw bytes of a single blob. Metadata lookup feeds
    /// the Content-Type + optional filename; the body is read via the
    /// blob manager (which handles its own caching). Failures come back as
    /// plain-text 4xx / 5xx so the browser surfaces them inline when the
    /// endpoint is loaded via `<img src>` etc.
    private func serveBlobContent(
        documentId: String, blobId: String,
        asDownload: Bool, writer: ResponseWriter
    ) async {
        guard let client, !documentId.isEmpty, !blobId.isEmpty else {
            writer.respondText("documentId + blobId required", status: 400)
            return
        }
        let ctx = client.documents.blobs(documentId: documentId)
        let contentType: String
        let filename: String?
        do {
            let meta = try await ctx.get(blobId: blobId)
            contentType = meta.contentType ?? "application/octet-stream"
            filename = meta.filename
        } catch {
            writer.respondText("blob metadata failed: \(error)", status: 502)
            return
        }
        do {
            let data = try await ctx.read(blobId: blobId)
            var headers: [String: String] = [:]
            if asDownload {
                let safeName = (filename ?? "blob-\(blobId)")
                    .replacingOccurrences(of: "\"", with: "")
                headers["Content-Disposition"] = "attachment; filename=\"\(safeName)\""
            }
            writer.respond(status: 200, contentType: contentType, body: data,
                           extraHeaders: headers)
        } catch {
            writer.respondText("blob read failed: \(error)", status: 502)
        }
    }

    /// Combined access-control view for one document: current permissions + pending invitations.
    /// Both come back as opaque JSON-like dicts from the REST API — we just surface them to the UI.
    @MainActor
    private func docPermissions(documentId: String) async -> [String: Any] {
        guard let client, !documentId.isEmpty else { return [:] }
        var result: [String: Any] = ["documentId": documentId]
        if let perms = try? await client.documents.getPermissions(documentId: documentId) {
            result["permissions"] = perms.map { $0.inspectorDict }
        } else {
            result["permissions"] = []
        }
        // Migrated off the deprecated `listInvitations` to `listPendingInvitations`.
        if let invites = try? await client.documents.listPendingInvitations(documentId: documentId) {
            result["invitations"] = invites.map { $0.inspectorDict }
        } else {
            result["invitations"] = []
        }
        return result
    }

    // MARK: - Event wiring

    private func subscribeToEvents(_ client: JsBaoClient) {
        let s: [EventSubscription] = [
            client.events.on(.status) { [weak self] (e: StatusChangedEvent) in
                self?.recordEvent(type: "status", fields: ["status": e.status.rawValue])
            },
            client.events.on(.networkMode) { [weak self] (e: NetworkModeEvent) in
                self?.recordEvent(type: "networkMode", fields: [
                    "mode": e.mode.rawValue,
                    "isOnline": e.isOnline,
                    "reason": e.reason ?? "",
                ])
            },
            // Document-lifecycle events: fed straight into the event ring
            // + SSE channel. Per-doc phase aggregation is derived
            // client-side now (tabs/performance.js :: perfPhaseFromEvent)
            // from these same fields.
            client.events.on(.documentLoaded) { [weak self] (e: DocumentLoadedEvent) in
                self?.recordEvent(type: "documentLoaded", fields: [
                    "documentId": e.documentId,
                    "source": e.source,
                    "hadData": e.hadData,
                    "bytes": e.bytes ?? 0,
                    "elapsedMs": Int(e.elapsedMs),
                ])
            },
            client.events.on(.documentClosed) { [weak self] (e: DocumentClosedEvent) in
                self?.recordEvent(type: "documentClosed", fields: ["documentId": e.documentId])
            },
            client.events.on(.sync) { [weak self] (e: SyncEvent) in
                self?.recordEvent(type: "sync", fields: [
                    "documentId": e.documentId,
                    "synced": e.synced,
                ])
            },
            client.events.on(.documentSyncStateChanged) { [weak self] (e: DocumentSyncStateChangedEvent) in
                self?.recordEvent(type: "documentSyncStateChanged", fields: [
                    "documentId": e.documentId,
                    "state": e.state,
                ])
            },
            client.events.on(.permission) { [weak self] (e: PermissionEvent) in
                self?.recordEvent(type: "permission", fields: [
                    "documentId": e.documentId,
                    "permission": e.permission.rawValue,
                ])
            },
            client.events.on(.authSuccess) { [weak self] (e: AuthSuccessEvent) in
                self?.recordEvent(type: "authSuccess", fields: ["cause": e.cause ?? ""])
            },
            client.events.on(.authFailed) { [weak self] (e: AuthFailedEvent) in
                self?.recordEvent(type: "authFailed", fields: [
                    "reason": e.reason ?? "",
                    "message": e.message ?? "",
                ])
            },
        ]

        lock.lock()
        subscriptions.append(contentsOf: s)
        lock.unlock()
    }

    private func recordEvent(type: String, fields: [String: Any]) {
        var record = fields
        record["type"] = type
        record["ts"] = Int(Date().timeIntervalSince1970 * 1000)

        lock.lock()
        events.append(record)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        let channels = sseChannels.filter { !$0.isClosed }
        sseChannels = channels
        lock.unlock()

        guard !channels.isEmpty else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let json = String(data: data, encoding: .utf8) else { return }
        for ch in channels { ch.sendEvent(name: "event", jsonData: json) }
    }
}
#endif
