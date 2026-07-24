# PrimitiveApp Library

This is a thin SwiftUI layer on top of [`JsBaoClient`](../../../swift-client/docs/README.md) that handles the boring-but-necessary parts of every Primitive app: loading config, owning the client, doing the auth dance, and exposing reactive state for documents and CRDT data.

If you've used the demo or template and you're wondering "what's this library actually giving me?" — start here.

## TL;DR

| You want to… | Use… |
|---|---|
| Own the JsBaoClient + connection state | `PrimitiveAppState` ([file](../Sources/PrimitiveApp/State/PrimitiveAppState.swift)) |
| Drop in a login screen | `AuthGateView` + `PrimitiveLoginView` ([file](../Sources/PrimitiveApp/Views/ConnectionStatusView.swift), [file](../Sources/PrimitiveApp/Views/PrimitiveLoginView.swift)) |
| Reactively load + reload data (REST or CRDT) | `BaoDataLoader<Data>` ([file](../Sources/PrimitiveApp/State/BaoDataLoader.swift)) |
| Two-way bind a `TextEditor` to a Y.Text | `LiveText` ([file](../Sources/PrimitiveApp/State/LiveText.swift)) |
| Show a profile/logout screen | `PrimitiveProfileView` ([file](../Sources/PrimitiveApp/Views/ProfileView.swift)) |
| Read `primitive.json` config | `loadPrimitiveAppConfig` ([file](../Sources/PrimitiveApp/Config/PrimitiveCredentials.swift)) |
| Use the underlying client directly | `appState.client` (a `JsBaoClient`) |

`@_exported import JsBaoClient` is in [PrimitiveApp.swift](../Sources/PrimitiveApp/PrimitiveApp.swift), so anywhere you `import PrimitiveApp` you also get the full `JsBaoClient` API for free — no second import needed.

## Source layout

```
swift-primitive-app/
├── Package.swift               ← SPM manifest, depends on JsBaoClient
├── Sources/PrimitiveApp/
│   ├── PrimitiveApp.swift      ← Module entry, re-exports JsBaoClient
│   ├── Config/
│   │   └── PrimitiveCredentials.swift   ← primitive.json loader
│   ├── State/
│   │   ├── PrimitiveAppState.swift      ← The big one. Owns client + auth + docs.
│   │   ├── PrimitiveAuthManager.swift   ← OAuth/magic link/OTP flows
│   │   ├── BaoDataLoader.swift        ← Generic reactive data loader (REST + CRDT)
│   │   └── LiveText.swift               ← Reactive wrapper over Y.Text
│   └── Views/
│       ├── ConnectionStatusView.swift   ← AuthGateView, ConnectionStatusView, PrimitiveLoadingView, DocumentSidebarView
│       ├── PrimitiveLoginView.swift     ← Login UI (magic link + OTP + OAuth)
│       ├── ProfileView.swift            ← PrimitiveProfileView (logout, user info)
│       └── ThemeManager.swift           ← PrimitiveThemeManager + PrimitiveThemeView (dark mode + accent color)
└── Tests/PrimitiveAppTests/
    ├── StringEditDeltaTests.swift       ← Tests for LiveText's UTF-16 diff helper
    └── BaoDataLoaderTests.swift         ← Tests for the loader's generation-counter race guards
```

The package is plain SPM — **adding a new file is just creating it on disk**, no project file edits. (Compare to [primitive-app-demo](../../primitive-app-demo) which uses an Xcode project and needs `project.pbxproj` updates.)

> **On `ObservableObject` vs `@Observable`, and login-view localization:** the library still uses `ObservableObject` + `@Published` and ships `PrimitiveLoginView` with hardcoded English. Both are deliberate. See [design-decisions.md](../../primitive-app-demo/docs/design-decisions.md) for the reasoning.

## The four concepts you actually need to know

### 1. `PrimitiveAppState` — owns everything

Think of this as your app's "session". Create one with `@StateObject` at the App level, inject it into the view tree as an `EnvironmentObject`, and it handles the rest.

```swift
@main
struct MyApp: App {
    @StateObject private var appState = PrimitiveAppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
```

What it owns:
- `client: JsBaoClient?` — the underlying SDK client. Created during `initialize()`.
- `appConfig: PrimitiveAppConfig?` — parsed `primitive.json`.
- `authManager: PrimitiveAuthManager` — exposed because views (login, profile) need to bind to it.

What it publishes (all `@Published`, so SwiftUI views auto-rerender):
- Connection: `isConnected`, `connectionStatus`, `statusColor`
- User: `userName`, `userEmail`, `userAvatarUrl`
- Documents: `documents: [PrimitiveDocumentInfo]`, `selectedDocId`, `isLoadingDocs`
- Sync: `isSyncing`, `isSynced`, `syncMessages`
- Errors: `errorMessage`
- Lifecycle: `isInitialized`

The lifecycle methods you call from your views:
- `initialize()` — load config, create the client. Call once from `.task`.
- `connectClient()` — open the WebSocket. `AuthGateView` calls this for you after auth succeeds.
- `fetchDocuments()` — refresh the `documents` array from the REST API. Already called as part of `connectClient()`.
- `selectDocument(_:)` — open a doc and start syncing it.
- `cleanup()` — tear everything down.

The override hooks (subclass and override these for typed Y.Doc data — see [BaoDataLoader section](#3-baodataloaderdata--reactive-data-loading) below):
- `onDocumentOpened(documentId:)` — called once a doc is open and connected to the shared store. Refresh your `@Published` model arrays here from the codegen facade (`items = ItemRecord.query()`); no per-doc model wrappers to construct. Make sure you registered your models in `connectClient()` (`GeneratedModels.register(on: client)`) so the facade sees the doc — see [swift-client codegen docs](../../../swift-client/docs/codegen.md).
- `onDocumentSynced(documentId:)` — called when initial sync completes.
- `onDocumentSyncStateChanged(documentId:state:)` — called when a remote change lands and the document reports `state == "synced"`.

> Real subclassing example: [DemoAppState.swift](../../primitive-app-demo/Sources/PrimitiveAppDemo/DemoAppState.swift) — resolves/opens the default document and reads its records through the codegen facade (`TaskRecord.query()` / `record.save(in:)`); no per-doc model wrappers.

### 2. `AuthGateView` + `PrimitiveAuthManager` — drop-in auth

You almost never have to write a login screen. Wrap your content in [`AuthGateView`](../Sources/PrimitiveApp/Views/ConnectionStatusView.swift) and it handles the whole state machine: loading → login → connecting → connected → offline.

```swift
var body: some View {
    AuthGateView(appName: "My App", authManager: appState.authManager) {
        MyMainContent()   // only renders once auth + connect succeed
    }
    .task { await appState.initialize() }
}
```

States the gate handles internally:
1. `!isInitialized` → "Initializing..." spinner
2. Initialized but unauthenticated → [`PrimitiveLoginView`](../Sources/PrimitiveApp/Views/PrimitiveLoginView.swift) (email magic-link + OTP + optional Google OAuth)
3. Authenticated but not connected → "Connecting..." spinner (auto-fires `connectClient()`)
4. Connected → your content
5. Was-connected-now-offline → still shows your content (offline-first)
6. `errorMessage` set → retry view

`PrimitiveAuthManager` is the thing actually doing the auth; `PrimitiveAppState` exposes one as `authManager`. You pass it to login/profile views by hand. Public methods you might call directly:
- `requestMagicLink(email:)`, `requestOtp(email:)`, `verifyOtp(email:code:)`
- `startOAuth()` — Google OAuth via `ASWebAuthenticationSession`
- `handleMagicLinkCallback(url:)` — for the URL scheme handler
- `logout()`

### 3. `BaoDataLoader<Data>` — reactive data loading

The Swift port of JS [`useBaoDataLoader`](../../primitive-app/src/composables/useBaoDataLoader.ts). One generic helper that handles "load some data, re-run when X changes, surface errors, debounce, gate on readiness." Generic over `Data` so it works for any return shape: a `[T]`, a single record, a `{ items, count, byCategory }` aggregation struct, anything.

It's a thin orchestrator. The interesting parts are:

1. **You provide `load: (JsBaoClient) async throws -> Data`** — the loader doesn't know or care what's inside.
2. **You provide `subscribeTo: [LoaderTrigger]`** — a list of event triggers that should cause a reload. Cases: `.onSync`, `.onDocumentSyncStateChanged`, `.onDocumentEvents` (matches JS's `reloadOnDocumentEvents` default), `.onConnect`, `.custom(...)`.
3. **`documentReady` is a settable property** — flip it from your view; the loader reloads on `false → true` and resets `initialDataLoaded` on `true → false`.
4. **`error` is `@Published`** — surface failures in your view directly, no `} catch {}` swallowing.
5. **Two reload methods** — `reload()` debounces (50ms default), `reloadNow()` is immediate (use after a known mutation).

The two real-world usage shapes:

**REST resource** (e.g. `client.collections.list()`):

```swift
@StateObject private var loader = BaoDataLoader<[CollectionItem]>()

.task {
    loader.documentReady = appState.isConnected
    loader.bind(
        client: appState.client,
        subscribeTo: [.onConnect]   // refresh after WS reconnect
    ) { client in
        let resp = try await client.collections.list(options: PaginationOptions(limit: 50))
        return (resp["items"] as? [[String: Any]] ?? []).map(CollectionItem.init)
    }
}
.onChange(of: appState.isConnected) { _, c in loader.documentReady = c }
.onDisappear { loader.unbind() }

// In body:
ForEach(loader.data ?? []) { ... }
if let error = loader.error { Text(error.localizedDescription).foregroundStyle(.red) }
```

**Codegen model records inside a Y.Doc** (typed CRDT data — codegen-emitted struct + the static `Model.query()`/`save(in:)` facade, see [swift-client codegen docs](../../../swift-client/docs/codegen.md)):

```swift
@StateObject private var loader = BaoDataLoader<[TaskRecord]>()

.task {
    loader.documentReady = demoState.isDefaultDocReady
    loader.bind(
        client: appState.client,
        subscribeTo: [.onModel(subscribe: TaskRecord.subscribe), .onSync]   // truly live: reloads on every TaskRecord change
    ) { _ in
        try TaskRecord.findAll()
    }
}
.onChange(of: demoState.isDefaultDocReady) { _, r in loader.documentReady = r }
.onDisappear { loader.unbind() }
```

The same loader handles both — the difference is which events you subscribe to, and what your `load` closure does.

**"Live" caveat.** For Y-CRDT records, "live updates" means truly live: a remote write lands → `.documentSyncStateChanged` reports `state == "synced"` → loader reloads → user sees the change with no action. For REST resources there's no server push, so "live" only means (a) reload on `.onConnect` after a reconnect and (b) manual `reloadNow()` after writes. Be honest with yourself about which you have.

**Multi-source loaders.** Because `Data` is generic, one loader can return derived/aggregated state from multiple server calls. [DatabasesDemo.swift](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/DatabasesDemo.swift) does this — its `dbViewLoader: BaoDataLoader<DbView>` loads `{ tasks, statusCounts }` in one closure with two parallel `client.databases.executeOperation` calls.

**When NOT to use it.** Action-on-demand flows (button → run a workflow / fire a webhook / execute a prompt) don't need a loader — they're not loading-on-view-open with reactive refresh. Several demos ([PromptsDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/PromptsDemo.swift), [WorkflowsDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/WorkflowsDemo.swift), [IntegrationsDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/IntegrationsDemo.swift)) intentionally stay as plain `@State` + button-driven async functions.

**Don't use it for things that already have a store.** Documents, for example, are exposed as `appState.documents: [PrimitiveDocumentInfo]` (a `@Published` array on `PrimitiveAppState` populated by `connectClient()`). Read from there directly — see [DocumentsCrudDemo.swift](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/DocumentsCrudDemo.swift). Building a per-page loader for the documents list would duplicate state and re-fetch unnecessarily.

> Real usage across the demo: [BaoModelCrudDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/BaoModelCrudDemo.swift), [QueriesDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/QueriesDemo.swift), [LiveUpdatesDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/LiveUpdatesDemo.swift), [CollectionsDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/CollectionsDemo.swift) (two interacting loaders), [DatabasesDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/DatabasesDemo.swift) (multi-source), [SharingDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/SharingDemo.swift), [BlobsDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/BlobsDemo.swift), [UsersGroupsDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/UsersGroupsDemo.swift), [WebhooksDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/WebhooksDemo.swift).

### 4. `LiveText` — bind a TextEditor to Y.Text

Y.Text is the CRDT type for character-level collaborative editing. [`LiveText`](../Sources/PrimitiveApp/State/LiveText.swift) wraps it for SwiftUI.

```swift
struct EditorView: View {
    @EnvironmentObject var appState: PrimitiveAppState
    @StateObject private var liveText = LiveText()

    var body: some View {
        TextEditor(text: liveText.binding)
            .task {
                liveText.bind(
                    client: appState.client,
                    documentId: docId,
                    name: "myDoc"   // the Y.Text name within the document
                )
            }
            .onDisappear { liveText.unbind() }
    }
}
```

The interesting part is what happens in the binding's `set` closure: every keystroke diffs the new value against the old, computes a minimal `(start, removeCount, insert)` delta in **UTF-16 units** (the indexing space Y.Text uses), and applies it as one `removeRange` + one `insert`. This is why two clients can type at the same time without clobbering each other — each character is its own CRDT op. Both the diff and the surrogate-pair handling are unit-tested in [`StringEditDeltaTests.swift`](../Tests/PrimitiveAppTests/StringEditDeltaTests.swift).

`LiveText` also tracks `lastRemoteUpdate: Date?` so you can show a "last edited X seconds ago" indicator.

> Real usage: [LiveUpdatesDemo.swift](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/LiveUpdatesDemo.swift) (the shared note section).

## Other public types worth knowing

**Views** ([Views/](../Sources/PrimitiveApp/Views/))

| Type | What it does |
|---|---|
| `AuthGateView` | The auth state machine wrapper — see above |
| `PrimitiveLoginView` | Email + OTP + (optional) Google OAuth login UI |
| `PrimitiveProfileView` | Profile + logout, takes a `PrimitiveAuthManager` |
| `ConnectionStatusView` | Tiny status pill (green/yellow/red dot + text) |
| `PrimitiveLoadingView` | Centered spinner with a message |
| `DocumentSidebarView` | List of `appState.documents` with selection binding |
| `PrimitiveThemeView` | Wrapper that applies a `PrimitiveThemeManager`'s color scheme + accent |

**State / Config**

| Type | What it does |
|---|---|
| `PrimitiveAppState` | Session — the big one |
| `PrimitiveAuthManager` | Auth flows + state |
| `BaoDataLoader<Data>` | Generic reactive data loader (REST or CRDT) |
| `LoaderTrigger` | Enum of event triggers for the loader's `subscribeTo` |
| `LiveText` | Reactive `Y.Text` reader/writer |
| `PrimitiveAppConfig` | Parsed `primitive.json` |
| `PrimitiveDocumentInfo` | `(id, title, permission)` doc metadata |
| `PrimitiveThemeManager` | Persistent dark mode + accent color |
| `loadPrimitiveAppConfig(searchPaths:)` | Free function — finds + parses `primitive.json` |
| `generateULID()` | Free function — sortable random ID for new records |

## Patterns that show up everywhere

**1. Subclass `PrimitiveAppState` and register your models.** The base class doesn't know about your record types. Register every codegen'd model **once at startup** by overriding `connectClient()` and calling `GeneratedModels.register(on: client)` right after `await super.connectClient()` — this mirrors each open document into the client's shared cross-document store so the facade and the debug inspector see it. The base class does **not** auto-register; this one line is each app's responsibility (it's a no-op until you add a model to `models.toml`).

Then read and write through the codegen facade — no per-doc model wrappers:

```swift
// read — cross-document, or scope to one doc with QueryOptions(documents: [documentId])
items = ItemRecord.query()
// write
try ItemRecord(title: "Hi").save(in: documentId)
```

Store results as `@Published` properties (typically refreshed in `onDocumentOpened` or via a `BaoDataLoader` `.onModel(subscribe:)`), then read them in views via `@EnvironmentObject var demoState: YourSubclass`. `ItemRecord` is the codegen-emitted struct produced by `swift-bao-codegen` from your `models.toml`; see [Swift model codegen](../../../swift-client/docs/codegen.md).

See [DemoAppState.swift](../../primitive-app-demo/Sources/PrimitiveAppDemo/DemoAppState.swift) for the canonical example.

**2. Inject the subclass twice, once as itself and once as the base.** SwiftUI's `@EnvironmentObject` lookup is by exact type. To let library views find `PrimitiveAppState` AND let your views find your subclass, inject both:

```swift
.environmentObject(appState as PrimitiveAppState)   // for library views like AuthGateView
.environmentObject(appState)                         // for your subclass (DemoAppState)
```

See [PrimitiveAppDemoApp.swift:22-23](../../primitive-app-demo/Sources/PrimitiveAppDemo/PrimitiveAppDemoApp.swift#L22-L23).

**3. Read from `appState.documents`, don't re-fetch.** `connectClient()` already populates it, `fetchDocuments()` keeps it fresh, and it's `@Published` so views update reactively. If you do your own `client.documents.list()` call you'll race against connect-time.

**4. Use `BaoDataLoader<Data>`'s `.bind(client:subscribeTo:load:)` from `.task`, and `.unbind()` from `.onDisappear`.** Bind once. If your data depends on a doc being open, set `loader.documentReady = ...` instead of conditionally binding — the loader's `documentReady` gate handles ready/not-ready transitions, including resetting `initialDataLoaded` if the doc closes.

**5. The loader is for *loadable* data, not for action-on-demand flows.** If your view shows the result of a button click ("execute prompt", "run workflow", "fire webhook") and there's no list to refresh on view-open, just use plain `@State` + an `async` action method. The loader's value comes from auto-refresh + error surfacing + initial load — none of which apply to action-on-demand patterns. Several demos ([PromptsDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/PromptsDemo.swift), [WorkflowsDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/WorkflowsDemo.swift), [IntegrationsDemo](../../primitive-app-demo/Sources/PrimitiveAppDemo/Views/Features/IntegrationsDemo.swift)) intentionally don't use it.

## Where to look next

- **Building a new app?** Start with [`primitive-swift-template`](../../../templates/primitive-swift-template/docs/README.md). It's the smallest possible consumer of this library.
- **Looking for a feature example?** [`primitive-app-demo`](../../primitive-app-demo/docs/README.md) has one demo page per JsBaoClient feature.
- **Debugging a running app?** [DebugInspector reference](./inspector.md) — the in-process HTTP dashboard that ships in every DEBUG build. Covers all 10 tabs, the HTTP surface, and how to add your own models / tests / tabs to it.
- **Need to drop down to the raw client?** [`JsBaoClient` docs](../../../swift-client/docs/README.md) — and `appState.client` gives you the instance.
- **Working on codegen model records?** [Swift model codegen](../../../swift-client/docs/codegen.md) covers the canonical `models.toml` → emitted struct → `Model.query()` / `save(in:)` facade flow in depth.
