# DebugInspector

A local HTTP dev-tool that exposes the live state of a running `JsBaoClient` to a web browser on the same LAN. DEBUG-only — the whole module is inside a single `#if DEBUG` guard and compiles to zero code in release builds.

The inspector's tabs are organized around the four storage layers a record passes through (server → Y.Doc CRDT in RAM → in-memory SQL projection → disk SQLite). Read [data-flow.md](./data-flow.md) for the conceptual map of where data lives at each moment; this doc focuses on the inspector itself.

- [Quick start](#quick-start)
- [How IPC works](#how-ipc-works)
- [File layout](#file-layout)
- [The tabs](#the-tabs)
  - [Overview](#overview)
  - [Documents](#documents)
  - [Tests](#tests)
  - [Databases](#databases)
  - [Collections](#collections)
  - [Blobs](#blobs)
  - [Performance](#performance)
  - [SQLite (disk)](#sqlite-disk)
  - [Memory SQL](#memory-sql)
  - [Events](#events)
  - [Logs](#logs)
- [HTTP surface](#http-surface)
- [Extension points](#extension-points)
  - [Add a new tab](#add-a-new-tab)
  - [Surface your models in the Records panel](#surface-your-models-in-the-records-panel)
  - [Register a test](#register-a-test)
  - [Add a new action or endpoint](#add-a-new-action-or-endpoint)
- [Security + limits](#security--limits)

## Quick start

1. Build your app in DEBUG (the default for `swift run`, `./run.sh`, `./run-ios.sh`, `./build.sh`, Xcode's Debug config).
2. Watch the terminal / Xcode console — when `PrimitiveAppState.initialize()` runs, the inspector prints a banner like:
   ```
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   [PrimitiveInspector] 01KN7M… listening on:
     http://localhost:9999
     http://192.168.1.42:9999
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ```
3. Open one of those URLs in any browser on the same LAN.

**Opt out** for a single run: `PRIMITIVE_DEBUG_INSPECTOR=0` in the environment. **Pin a port** if 9999 is taken: `PRIMITIVE_DEBUG_INSPECTOR_PORT=9998`.

## How IPC works

The iOS app runs a tiny **HTTP server inside its own process** (in DEBUG builds only). That server binds TCP port 9999 on whatever network interfaces the device has. Your Mac's browser is an HTTP client like any other — it hits `http://<device>:9999/` and speaks plain HTTP. Every interactive bit of the inspector UI is either (a) a `fetch()` for state, (b) an `EventSource` for the live event stream, or (c) a `POST /api/action/*` whose handler on the iOS side calls the corresponding `JsBaoClient` method on the main actor.

That's it. No RPC framework, no native bridge, no WebSocket, no bonus processes. Plain HTTP.

### Why this works at all

- iOS apps are allowed to run HTTP servers. There's no sandbox restriction on `bind()`.
- `Network.framework` (Apple's native networking lib) has `NWListener`, which is a TCP server primitive. We use it with no dependencies.
- The simulator shares the Mac's loopback interface, so `localhost:9999` from the Mac hits the simulator's listener directly.
- On a physical device, Local Network permission (iOS 14+) gates LAN traffic. We declare `NSLocalNetworkUsageDescription` + `NSBonjourServices` and advertise a Bonjour service from the listener, which triggers the one-time permission prompt and lets the Mac actually talk to the phone over Wi-Fi.

### Architecture

```
┌────────────────────────────┐           ┌────────────────────────────┐
│ iOS/macOS app (DEBUG)      │           │ Mac browser                │
│                            │   HTTP    │                            │
│  JsBaoClient               │ ←───────→ │   shell.html               │
│       ▲                    │           │   (Tailwind CDN + Alpine)  │
│       │ (main-actor calls) │           │   /api/* fetch + SSE       │
│  DebugInspector ──┐        │           │                            │
│                   ├─ router│           │                            │
│  DebugHTTPServer ─┘        │           │                            │
│  (NWListener :9999)        │           │                            │
└────────────────────────────┘           └────────────────────────────┘
```

**`DebugHTTPServer`** — [Sources/PrimitiveApp/Debug/DebugHTTPServer.swift](../Sources/PrimitiveApp/Debug/DebugHTTPServer.swift). ~250 lines of HTTP/1.1 parsing over `NWListener` + `NWConnection`. GET + POST, with Server-Sent Events as a third response mode. No keep-alive — every request gets its own TCP connection. Fine for a dev tool. `ResponseWriter.respond(status:contentType:body:extraHeaders:)` lets routes return raw bytes with arbitrary headers (used for blob content downloads).

**`DebugInspector`** — [Sources/PrimitiveApp/Debug/DebugInspector.swift](../Sources/PrimitiveApp/Debug/DebugInspector.swift). Owns the router closure given to the HTTP server. Holds weak references to the `JsBaoClient` and the `PrimitiveAppState` so it can read live state on demand. Also subscribes to `client.events` once at startup — every incoming event goes into a ring buffer and gets fanned out to any SSE subscribers.

**`InspectorHTML`** — [Sources/PrimitiveApp/Debug/InspectorHTML.swift](../Sources/PrimitiveApp/Debug/InspectorHTML.swift). Assembles the single-page UI at first access from the split resource tree. Caches the assembled page for the process lifetime.

## File layout

```
Sources/PrimitiveApp/Debug/
├── DebugHTTPServer.swift        ← NWListener + request parsing + SSE
├── DebugInspector.swift         ← server-side routes + action dispatcher + event capture
├── InspectableModel.swift       ← public InspectableModel + Host protocol
├── InspectorTest.swift          ← public InspectorTest + Host protocol
├── InspectorLog.swift           ← in-process ring buffer surfaced on the Logs tab
├── InspectorSQLiteReader.swift  ← read-only reader for the client's kv_store
├── InspectorHTML.swift          ← assembles ui/shell.html from the per-tab fragments
└── ui/
    ├── shell.html               ← outer HTML: head, header, tab nav, placeholders
    ├── core.css                 ← shared styles
    ├── core.js                  ← Alpine factory base: tabs list, lifecycle, SSE,
    │                              fetchSnapshot, doAction, shared formatters;
    │                              contains /*__INSPECTOR_TABS_JS__*/ placeholder
    └── tabs/
        ├── overview.html    + overview.js
        ├── documents.html   + documents.js
        ├── tests.html       + tests.js
        ├── databases.html   + databases.js
        ├── collections.html + collections.js
        ├── blobs.html       + blobs.js
        ├── performance.html + performance.js
        ├── sqlite.html      + sqlite.js     ← disk-side `kv_store` browser
        ├── memdb.html       + memdb.js      ← in-memory query engine browser
        ├── events.html      + events.js
        └── logs.html        + logs.js
```

Each `tabs/{name}.{html,js}` pair is owned by one tab and never referenced from another. Shared state (the doc list, the SSE event stream, `doAction`) lives in `core.js`; per-tab state/getters/methods live in the tab files.

### How the page gets assembled

At first access of `InspectorHTML.page`:

1. Load `ui/shell.html`.
2. Load `ui/core.css` → substitute into `/*__INSPECTOR_CSS_PLACEHOLDER__*/` inside `<style>` of shell.
3. For each tab in `InspectorHTML.tabOrder`, load `ui/tabs/{name}.html` → concatenate → substitute into `<!--__INSPECTOR_TABS_HTML__-->` inside `<main>` of shell.
4. Load `ui/core.js`, then each `ui/tabs/{name}.js` in `tabOrder`. Concatenate all as plain JS (no placeholder splice — see below) and substitute into `/*__INSPECTOR_JS_PLACEHOLDER__*/` inside `<script>` of shell.

Each tab JS file is a **standalone, lintable JavaScript file** that declares a factory function like:

```js
function overviewTab() {
  return {
    // state, getters, methods for this tab
  };
}
```

At runtime, `core.js` exposes one `inspector()` function (the `x-data` factory) that builds the shared-state base and then merges each tab's factory return using `Object.defineProperties(base, Object.getOwnPropertyDescriptors(overviewTab()))`. That preserves getter accessors — plain `Object.assign` would snapshot a getter's return value to a data property and break reactivity.

Tab factory names are listed in `core.js`'s `__INSPECTOR_TAB_FACTORIES__` array; missing factories are skipped silently, so adding/removing tabs doesn't require an atomic update across multiple files.

Because every tab ends up as properties on the single flat object Alpine wraps, `this.anythingFromAnyTab` inside a method or getter dispatches through Alpine's proxy just like before — cross-tab state access keeps working.

## The tabs

### Overview

Read-only dashboard showing connection state, the current user, a document summary, a SQLite storage summary, and a tail of the last ~20 events. No exclusive state (see [overview.js](../Sources/PrimitiveApp/Debug/ui/tabs/overview.js) — just a comment). Everything it renders comes from `conn` / `user` / `docs` / `events` owned by [core.js](../Sources/PrimitiveApp/Debug/ui/core.js).

### Documents

Three-column CRUD for documents + a per-model records browser.

- **Left**: filterable doc list, color-coded for open/pending/local-only. Click auto-opens the doc.
- **Middle**: "Records" table — pick one of the registered `InspectableModel`s for the currently-selected doc, see its rows, add new records via a schema-typed form (inputs dispatched by field `kind`: string/number/boolean/date/id/stringset/json), delete rows.
- **Right**: detail for the selected doc (rename / close / delete / share) and raw metadata.

Sources: [documents.html](../Sources/PrimitiveApp/Debug/ui/tabs/documents.html), [documents.js](../Sources/PrimitiveApp/Debug/ui/tabs/documents.js).

Requires the host to conform to `InspectableModelHost` ([InspectableModel.swift](../Sources/PrimitiveApp/Debug/InspectableModel.swift)) — see [Surface your models](#surface-your-models-in-the-records-panel).

### Tests

Runs `InspectorTest`s the host registers via `InspectorTestHost`. Tests run sequentially via `/api/action/test/run`; each test's output streams into the right pane, and per-test pass/fail + duration shows in the tree on the left.

- Run selected / Run all / Run one / Clear results.
- Copy all output / copy only failed output to the clipboard.
- Tests are pure Swift closures — can exercise real client methods, assert through `ctx.check(...)`, and log via `ctx.log(...)`.

Sources: [tests.html](../Sources/PrimitiveApp/Debug/ui/tabs/tests.html), [tests.js](../Sources/PrimitiveApp/Debug/ui/tabs/tests.js). Protocol: [InspectorTest.swift](../Sources/PrimitiveApp/Debug/InspectorTest.swift).

See [Register a test](#register-a-test).

### Databases

Two-surface view over server-side databases (`/databases/...`). A single left list + detail view on the right with two parallel CRUD paths:

1. **Models (primary)** — the **admin-data** path. Generic CRUD on rows regardless of whether the app developer registered operations. Server-gated to app admins + db owners. The server routes `POST /databases/:id/admin-data/{query,save,delete,patch}` bypass CEL rules — this is the debugging door. If the current user isn't an admin/owner, the query returns 401/403; the UI auto-expands the **Registered operations** fallback and surfaces a clear explanation.
2. **Registered operations (secondary, collapsible)** — the **production** path. CEL-gated, app-defined named operations that the app developer registers via `DatabasesAPI.createOperation(databaseId:, params:)`. Anyone with access to the database can execute an operation within its CEL rule. Clicking an operation runs it and renders the result as a table (array of dicts) or raw JSON.

Both paths coexist so any user can interact with any database: admins/owners browse raw via the Models path; everyone else uses the operations path.

Sources: [databases.html](../Sources/PrimitiveApp/Debug/ui/tabs/databases.html), [databases.js](../Sources/PrimitiveApp/Debug/ui/tabs/databases.js). Server wiring: the `db/*` and `db/records/*` cases in [DebugInspector.swift](../Sources/PrimitiveApp/Debug/DebugInspector.swift).

### Collections

Two-column CRUD for collections of documents. Left = filter + list + create form. Right = selected collection detail with:

- **Actions**: rename / delete
- **Documents in this collection**: list with per-row remove, + add-by-documentId
- **Access**: raw getAccess() dump plus `+ grant group` and `+ add member` prompts

Sources: [collections.html](../Sources/PrimitiveApp/Debug/ui/tabs/collections.html), [collections.js](../Sources/PrimitiveApp/Debug/ui/tabs/collections.js). Server wiring: the `col/*` cases in DebugInspector.

### Blobs

Two-column file browser, scoped to whichever document is selected on the Documents tab (js-bao-wss doesn't support doc-less blobs as of this writing).

- **Left**: blob list + file-picker "upload" button. Upload path is `FileReader → ArrayBuffer → base64 → POST /api/action/blob/upload`, which calls `DocumentBlobContext.upload(data:options:)` on the server.
- **Right**: selected blob detail + in-browser preview:
  - `image/*` → inline `<img>` pointing at `/api/blob/content?documentId=…&blobId=…`
  - `text/*` / `application/json|javascript|xml|yaml|toml` → on-demand UTF-8 decode shown in a `<pre>`
  - Everything else → an "open / download" link pair (download adds `Content-Disposition: attachment`)

Sources: [blobs.html](../Sources/PrimitiveApp/Debug/ui/tabs/blobs.html), [blobs.js](../Sources/PrimitiveApp/Debug/ui/tabs/blobs.js).

### Performance

A **live** chronological timeline of every document-level phase event the inspector has seen — `loadedFromSqlite`, `loadedFromServer`, `synced`, `remoteUpdate`, `closed` — with plain-English labels and icons. Summary cards at the top totalize sqlite vs server volume + timing. No refresh button: the whole view is derived from the SSE event stream that core.js consumes continuously, so new events appear the instant they arrive.

The goal: someone with no jsbao familiarity should be able to read the timeline and answer "what data was loaded, from where, in how long?" Each `synced` event is annotated with the models that became available on that doc (cross-referenced against `InspectableModelHost`).

Filter-by-doc dropdown lets you isolate one doc's trace when multiple docs are syncing concurrently.

Sources: [performance.html](../Sources/PrimitiveApp/Debug/ui/tabs/performance.html), [performance.js](../Sources/PrimitiveApp/Debug/ui/tabs/performance.js). Derivation: `perfPhaseFromEvent(e)` in performance.js maps each SSE event (`documentLoaded` → `loadedFromSqlite`/`loadedFromServer`, `sync`→`synced`, `remoteUpdate`→`remoteUpdate`, `documentClosed`→`closed`) into a phase row. The `events` array (capped at 1000, with the last 500 replayed on connect so new tabs don't paint empty) drives `perfTimeline` + `perfSummary` via computed getters, so Alpine re-renders automatically on each new event.

### SQLite (disk)

Read-only browser over the client's **on-disk** `kv_store` SQLite database — the file at `<Documents>/JsBaoClient/<appId>:<userId>/jsbao_storage.sqlite`. This is the durability layer (the `yjs_docs` blobs, `meta`, `kv`, `auth`), not the query layer. For per-model SQL tables that back `model.query()`, use the [Memory SQL](#memory-sql) tab.

Table tabs along the top show every `store` name with its row count; clicking loads the rows (key, value, metadata, updatedAt) with most-recently-updated first.

The client writes to this database in WAL mode, so the inspector opens its own `SQLITE_OPEN_READWRITE` connection per query to see committed rows without waiting for checkpoint.

`yjs_docs` rows are *encoded Y.Doc CRDT bytes* — they look like base64 blobs because that's what they are. To see the records inside, look at the [Documents](#documents) tab (live YMap walk) or [Memory SQL](#memory-sql) tab (per-model SQL projection). See [data-flow.md](./data-flow.md) for why those exist as separate layers.

The **diag** toggle in the header opens a "resolution trace" panel showing:
- The `appId` the reader is scanning for
- The filesystem roots it checked (sandboxed container path on macOS, Documents on iOS)
- Every `appId:*` subdir found, with mtime — so you can see which one the reader picked as most-recent
- The resolved `jsbao_storage.sqlite` path (or `(none)` if unresolved)
- A file probe: open status, file size, WAL/SHM size, journal mode, listed tables, kv_store row counts pre- and post-`wal_checkpoint(PASSIVE)`

If the tab looks blank, diag will say why — typically "no logged-in namespace dir yet". A pre/post checkpoint count divergence flags WAL visibility issues.

Sources: [sqlite.html](../Sources/PrimitiveApp/Debug/ui/tabs/sqlite.html), [sqlite.js](../Sources/PrimitiveApp/Debug/ui/tabs/sqlite.js). Reader: [InspectorSQLiteReader.swift](../Sources/PrimitiveApp/Debug/InspectorSQLiteReader.swift).

### Memory SQL

Live browser + ad-hoc query runner over the **in-memory** SQLite that backs `model.query() / count / aggregate / queryPaged / findByUnique` — the `BaoModelQueryEngine`. Lives entirely in RAM (`sqlite3_open(":memory:")`), kept in sync with the Y.Doc via the update observer, never written to disk.

Each `DynamicModel` (and the `TypedModel<T>` wrapping it) owns its own engine instance, so the tab lists models flat across the top. Below the model picker, a one-line context strip shows the model name and the **documentId** the projection is bound to — the engine is per-(model, doc), so this clarifies which scope you're looking at.

**Polling.** While the tab is active, the catalog + active table refresh every 2s ([core.js:120](../Sources/PrimitiveApp/Debug/ui/core.js#L120)). The header shows a green dot + "live (2s)" while polling, and a button to pause/resume — useful when you're staring at a single value and don't want it flickering, or when you need a stable result set for a screenshot.

**Schema strip.** Just under the table picker, `PRAGMA table_info` columns for the active table — name, type, PK flag, NOT NULL flag — so you can see what an indexed query actually hits. Hidden when a custom query result is on screen so the strip always reflects what's displayed.

**Table view.** The body is a true SQL table: sticky header, columns from the schema, rows truncated to ~320px wide (full value on hover via `title`), `NULL` in italics for missing values. Each row in the main table has a `del` button that routes through `record/delete` (which writes through `DynamicModel.delete` → Y.Doc → engine projection — *not* a direct SQL DELETE).

**Create row.** A `+ new row` button above the table opens a modal. Inputs are dispatched by field `kind` (string/number/boolean/date/id/stringset/json). Submit → `record/create` action → `DynamicModel.create` (Y.Doc → engine projection). Schema-required fields are flagged in the form.

**Custom query box.** Above the schema strip, a SQL textarea with **run** / **clear** buttons (Cmd/Ctrl+Enter to run). Hits the `/api/action/memdb/exec` action which:
- accepts only `SELECT`, `PRAGMA`, and `WITH` (CTE) statements,
- runs them against the model's engine via `rawQuery`,
- returns rows with column names sorted alphabetically (`id` and `_meta_doc_id` pinned first).

**Direct DML is rejected.** Writes against the engine would desync the projection from its Y.Doc source of truth — and the next observer-driven sync would clobber the changes anyway. For CRUD, use the row controls (delete, new row) which go through Y.Doc, or do it from the [Documents](#documents) tab.

Useful for answering:
- "What columns does the engine project for this model?" (esp. the auto-generated `_meta_doc_id` when an engine is shared across docs)
- "Are stringset fields populating their junction table on writes?" (junction tables show up next to the main table in the picker)
- "Are SQL rows in sync with the YMap?" — compare Memory SQL rows against [Documents](#documents) tab records; they should match exactly
- "How does my filter/index actually translate to SQL?" — write the same query in the box and see the results

Backed by the public `inspectionQueryEngine` accessor on `DynamicModel` (which exposes [`BaoModelQueryEngine`](../../../js-bao-wss/swift-client/Sources/JsBaoClient/Query/BaoModelQueryEngine.swift)) and the `InspectableMemoryDB` wrapper on [InspectableModel.swift](../Sources/PrimitiveApp/Debug/InspectableModel.swift). Legacy `BaoModel<T>` instances don't surface a `memoryDB` yet — their mirror lives in a different place. Models surfaced via the runtime-schema factory (`TypedModel<T>` / `DynamicModel`) are picked up automatically.

Sources: [memdb.html](../Sources/PrimitiveApp/Debug/ui/tabs/memdb.html), [memdb.js](../Sources/PrimitiveApp/Debug/ui/tabs/memdb.js).

### Events

The full live event stream from `client.events` as a filterable log. Pause / auto-scroll / filter-by-type / text filter. The stream is captured continuously (not tab-gated), so switching back to this tab shows you didn't miss anything.

Sources: [events.html](../Sources/PrimitiveApp/Debug/ui/tabs/events.html), [events.js](../Sources/PrimitiveApp/Debug/ui/tabs/events.js). SSE wiring is in [core.js](../Sources/PrimitiveApp/Debug/ui/core.js) (`connectEvents` + `pushEvent`).

### Logs

Inspector-internal log tail — HTTP 404s, failed actions, SQLite errors, internal warnings. Lightly self-refreshes while active (every 1.5s) so failed actions surface immediately. `doAction()` also calls `loadLogs()` on every failure so the next time you look, the same error has richer context.

Sources: [logs.html](../Sources/PrimitiveApp/Debug/ui/tabs/logs.html), [logs.js](../Sources/PrimitiveApp/Debug/ui/tabs/logs.js). Writer: [InspectorLog.swift](../Sources/PrimitiveApp/Debug/InspectorLog.swift).

## HTTP surface

All routes are served by [DebugInspector.route(_:writer:)](../Sources/PrimitiveApp/Debug/DebugInspector.swift).

### Bulk state — polled every 2s by the UI

| Verb | Path | Returns |
|------|------|---------|
| `GET` | `/api/snapshot` | Connection, user, documents, SQLite stores/rowcounts, selection |
| `GET` | `/api/models` | List of registered `InspectableModel`s (name, fields, documentId, read-only flag, canCreate flag) |
| `GET` | `/api/models/<name>?documentId=…` | Records for that model, as JSON rows |
| `GET` | `/api/tests` | Registered `InspectorTest`s |
| `GET` | `/api/logs` | Inspector-internal log tail |
| `GET` | `/api/collections` | Collections list |
| `GET` | `/api/collections/:id/documents` | Documents inside a collection |
| `GET` | `/api/collections/:id/access` | Access control snapshot |
| `GET` | `/api/databases` | Databases list |
| `GET` | `/api/db/models?databaseId=…` | Model names stored in the database (DO's `/records/models`) |
| `GET` | `/api/db/describe?databaseId=…&modelName=…` | Inferred field descriptors for a model |
| `GET` | `/api/db/operations?databaseId=…` | Registered operations (CEL-gated) |
| `GET` | `/api/sqlite/store/<name>?limit=…&offset=…` | Raw `kv_store` rows for one store |
| `GET` | `/api/sqlite/diag` | Disk SQLite resolution diagnostics (see [SQLite (disk)](#sqlite-disk) tab) |
| `GET` | `/api/memdb` | Catalog of in-memory SQL projections — one entry per model with its tables + row counts |
| `GET` | `/api/memdb/columns?model=…&documentId=…&table=…` | `PRAGMA table_info` for one in-memory table |
| `GET` | `/api/memdb/rows?model=…&documentId=…&table=…&limit=…` | `SELECT * FROM table LIMIT N` against the in-memory engine |
| `GET` | `/api/blobs?documentId=…` | Blob metadata list for a document |
| `GET` | `/api/blob/content?documentId=…&blobId=…[&download=1]` | Raw blob bytes with correct Content-Type; adds `Content-Disposition: attachment` when `download=1` |
| `GET` | `/api/doc/permissions?documentId=…` | Permissions + pending invitations for a document |

### Live event stream

| Verb | Path | Returns |
|------|------|---------|
| `GET` | `/api/events` | Server-Sent-Events stream. First frame (`init`) replays the last 500 buffered events so new tabs aren't empty; subsequent frames (`event`) push as `client.events` fires |

### Mutations — `POST /api/action/<verb>` with a JSON body

Every mutation flows through one dispatcher. Body gets parsed, the dispatcher hops to `@MainActor`, and the appropriate `JsBaoClient` or `PrimitiveAppState` method gets called. Response is always `{ ok: Bool, error?: String, …extras }`.

| Action | Body | Calls |
|--------|------|-------|
| `doc/create` | `{ title?, tags? }` | `client.documents.create(options:)` — server mints ULID |
| `doc/rename` | `{ documentId, title }` | `client.documents.update(documentId:data:)` |
| `doc/delete` | `{ documentId }` | `client.documents.delete(documentId:)` |
| `doc/open`   | `{ documentId }` | `appState.selectDocumentAwaiting(_:)` — awaits full sync |
| `doc/close`  | `{ documentId }` | `client.closeDocument(_:)` |
| `doc/share`  | `{ documentId, email, permission }` | `client.documents.sendInvitation(documentId:email:permission:)` |
| `record/create` | `{ model, documentId, values }` | `InspectableModel.createWith(values)` — generates ULID when id absent |
| `record/delete` | `{ model, documentId, id }` | `InspectableModel.deleteById(id)` |
| `test/run` | `{ id }` | runs one `InspectorTest`, returns passed/durationMs/output/error |
| `blob/upload` | `{ documentId, filename, contentType, data (base64) }` | `DocumentBlobContext.upload(data:options:)` |
| `blob/delete` | `{ documentId, blobId }` | `DocumentBlobContext.delete(blobId:)` |
| `col/create` | `{ name }` | `client.collections.create(params:)` |
| `col/rename` | `{ collectionId, name }` | `client.collections.update(collectionId:params:)` |
| `col/delete` | `{ collectionId }` | `client.collections.delete(collectionId:)` |
| `col/addDoc` / `col/removeDoc` | `{ collectionId, documentId }` | `client.collections.{addDocument,removeDocument}(...)` |
| `col/grant` / `col/revoke` | `{ collectionId, groupType, groupId, permission? }` | `client.collections.{grantGroupPermission,revokeGroupPermission}(...)` |
| `col/addMember` / `col/removeMember` | `{ collectionId, userId, permission? }` | `client.collections.{addMember,removeMember}(...)` |
| `db/create` | `{ title, databaseType? }` | `client.databases.create(params:)` |
| `db/rename` | `{ databaseId, title }` | `client.databases.update(databaseId:params:)` |
| `db/delete` | `{ databaseId }` | `client.databases.delete(databaseId:)` |
| `db/execute` | `{ databaseId, name, options? }` | `client.databases.executeOperation(databaseId:name:options:)` (CEL-gated) |
| `db/records/query` | `{ databaseId, modelName, filter?, options? }` | `POST /databases/:id/admin-data/query` (admin-only) |
| `db/records/create` | `{ databaseId, modelName, data, id? }` | `POST /databases/:id/admin-data/save` (admin-only) |
| `db/records/patch` | `{ databaseId, modelName, id, data }` | `POST /databases/:id/admin-data/patch` (admin-only) |
| `db/records/delete` | `{ databaseId, modelName, id }` | `POST /databases/:id/admin-data/delete` (admin-only) |
| `memdb/exec` | `{ model, documentId, sql }` | `BaoModelQueryEngine.rawQuery(...)` — server-side reject if the SQL isn't `SELECT`/`PRAGMA`/`WITH` |

## Extension points

### Add a new tab

1. Register it in the tabs list in [core.js](../Sources/PrimitiveApp/Debug/ui/core.js):
   ```js
   tabs: [
     …,
     { id: 'mytab', label: 'My Tab' },
   ],
   ```
2. Also add `'mytabTab'` to `__INSPECTOR_TAB_FACTORIES__` in core.js (same order as the UI list).
3. Drop `ui/tabs/mytab.html` with a `<section x-show="activeTab === 'mytab'">…</section>` root.
4. Drop `ui/tabs/mytab.js` defining the factory:
   ```js
   function mytabTab() {
     return {
       // state, getters, methods — this is valid standalone JS
     };
   }
   ```
   At runtime, `inspector()` calls `mytabTab()` and merges the return onto the Alpine state object via `Object.defineProperties`. Getters work; `this.xxx` inside methods/getters sees every other tab's state/methods too.
5. Add `"mytab"` to `tabOrder` in [InspectorHTML.swift](../Sources/PrimitiveApp/Debug/InspectorHTML.swift) at the position you want the HTML section + JS file to appear.
6. If the tab needs server routes, add them to [DebugInspector.swift](../Sources/PrimitiveApp/Debug/DebugInspector.swift). `GET` → `route(_:writer:)` switch. `POST /api/action/...` → `dispatchAction(_:body:)` switch. See [Add a new action or endpoint](#add-a-new-action-or-endpoint).

No `Package.swift` update is needed — the target already uses `.process("Debug/ui")` which recursively picks up everything under the `ui` directory.

### Surface your models in the Records panel

Conform your `PrimitiveAppState` subclass to [`InspectableModelHost`](../Sources/PrimitiveApp/Debug/InspectableModel.swift) and return one `InspectableModel` per model you want the inspector to browse:

```swift
extension MyAppState: InspectableModelHost {
  var inspectableModels: [InspectableModel] {
    guard let docId = modelsDocId else { return [] }   // whichever doc is currently open
    var out: [InspectableModel] = []
    if let m = taskModel     { out.append(.from(m, documentId: docId)) }
    if let m = productModel  { out.append(.from(m, documentId: docId)) }
    return out
  }
}
```

Three factories for `InspectableModel.from(...)`, picked automatically by overload:

- `from<T: BaoModelRecord>(BaoModel<T>, documentId:, name:)` — legacy typed models
- `from<T: PrimitiveModel>(TypedModel<T>, documentId:, name:)` — runtime-schema typed structs
- `from(DynamicModel, documentId:, name:)` — pure runtime schema, no native Swift type

Each factory wires `loadAll`, `deleteById`, and `createWith` so the Records table, "delete row" buttons, and "new record" form all work with zero extra code. Field descriptors come from the model's schema — the inspector dispatches inputs by `kind` (string/number/boolean/date/id/stringset/json) automatically.

### Register a test

Conform your `PrimitiveAppState` subclass to [`InspectorTestHost`](../Sources/PrimitiveApp/Debug/InspectorTest.swift):

```swift
extension MyAppState: InspectorTestHost {
  var inspectorTests: [InspectorTest] {
    [
      InspectorTest(group: "Client", name: "is connected") { [weak self] ctx in
        guard let self, let client = self.client else { throw TestFailure(message: "no client") }
        ctx.log("connection id: \(client.connectionId)")
        try ctx.check(client.isConnected, "client is not connected")
      },
      // … more tests …
    ]
  }
}
```

Tests run on the main actor, so they can touch `@MainActor`-isolated state directly. `ctx.log` accumulates output; `ctx.check(Bool, String)` throws `TestFailure` on false; any `Error` thrown from the closure marks the test failed with its `description`.

Tests are generally the fastest way to build a repro for a bug — add a test that does the minimum setup to reproduce, then iterate from there.

### Add a new action or endpoint

**Read (`GET /api/foo`):**

1. Add a `case "/api/foo":` to the GET switch in [DebugInspector.route(_:writer:)](../Sources/PrimitiveApp/Debug/DebugInspector.swift).
2. Dispatch to a helper (typically `@MainActor` so it can read live state): `Task { let payload = await self?.fooPayload() ?? [:]; writer.respondJSON(payload) }`.

**Mutation (`POST /api/action/foo`):**

1. Add a `case "foo":` to `dispatchAction(_:body:)`. The enclosing `do/catch` already handles `HttpError` (HTTP status codes + server body), `JsBaoError` (typed codes), `AuthError`, and fallthrough Swift errors — just return `["ok": true, …extras]` on success or let a throw propagate.
2. Call it from the JS side via `this.doAction('foo', { …body })`. `doAction` surfaces failures as an `alert()` + flips to the Logs tab with the full error context.

## Security + limits

**It's always scoped to DEBUG builds.** The entire Inspector module is inside a single `#if DEBUG` guard. Release builds compile it out; the HTTP port is never opened, no events are captured, no Bonjour advertisement goes out. UI resources still ship (SPM can't conditionally bundle), but they're never read without the Swift code.

**It's gated by Local Network permission on iOS.** The first time the app binds its `NWListener`-with-Bonjour, iOS shows a permission prompt. Until the user accepts, iOS silently drops LAN data at the application layer. That's why the current `network.server` entitlement + the `NSLocalNetworkUsageDescription` / `NSBonjourServices` Info.plist keys are necessary — they're not cosmetic.

### Release-bundle caveat (Info.plist + resources ship unconditionally)

SPM can't conditionally bundle resources, and Info.plist keys declared in `project.yml` apply to every configuration. In practice this means Release builds still carry:

- the `ui/` resource tree (`shell.html`, `core.{css,js}`, all `tabs/*`) — ~60 KB of dead weight. Nothing reads them because every `InspectorHTML` / `DebugInspector` symbol is excluded by `#if DEBUG`, but the files exist in the bundle.
- `NSLocalNetworkUsageDescription`, `NSBonjourServices`, and the `com.apple.security.network.server` entitlement. Safe behaviorally — nothing binds an `NWListener` in Release, so iOS never prompts — but an App Store reviewer may ask why the app declares local-network access.

Neither is a correctness problem, just noise. If either bites you when shipping, gate them on build configuration:

- **Resources**: add a build-phase script to strip `ui/` from `PrimitiveApp_PrimitiveApp.bundle` in Release, or move the inspector to a separate Debug-only target.
- **Info.plist + entitlement**: either use a build-phase script to remove those keys in Release, or switch `project.yml` to configuration-specific `settings:` blocks (`configs: { Release: { ... } }` drops the INFOPLIST_KEY_* lines there).

Both are straightforward but deliberately not wired up by default — the dev tool stays one-source-tree, zero-configuration until you're ready to ship for real.

**No authentication.** Any HTTP client on the same LAN can hit the endpoints. For a dev tool on your personal dev network, fine. Don't run DEBUG builds on public Wi-Fi, and don't ship the inspector in a TestFlight build that goes to external testers (the `#if DEBUG` guard handles this as long as you don't flip the build config).

**The listener binds all `en*` interfaces.** Wi-Fi and Ethernet — on both iOS and macOS. Cellular, VPN tunnels, AirDrop peers are filtered out, because their IPs aren't reachable from the dev's Mac.

**Cross-machine latency.** Every action is a round-trip over Wi-Fi: ~5–20ms on a good LAN, up to 100ms on busy networks. Fine for debugging, visibly not real-time. The event stream is push-based (SSE), so observation lag is low even when action lag isn't.

## Alternatives we considered

- **USB port-forwarding** (`iproxy`). Works fine and bypasses all iOS LAN gates. Still supported as a fallback when the phone's not on the same Wi-Fi, or when you want a cable-only workflow.
- **Native Mac companion app.** Nicer UI story but requires maintaining a second Xcode target and a bespoke transport. Not obviously better for a debug tool whose UI we want to iterate on in minutes.
- **WebSocket instead of SSE for events.** We picked SSE — one-way push, native `EventSource` in the browser, no framing protocol to implement. The server never needs the browser to send it messages on the event channel; mutations go through dedicated `POST` endpoints.
- **JS bundler (esbuild/vite/TypeScript).** Overkill for a debug tool. The per-tab split + Alpine's factory-of-object pattern gives us real file-per-tab editor support with zero build step.
