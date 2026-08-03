# Data flow: server → client → memory → disk

A practical reference for *where your data lives at any given moment* and *when it moves between layers*. Read this when the inspector shows something surprising.

The client has **four** distinct stages your data passes through, and each one stores it in a different shape:

```
┌───────────┐      ┌─────────────────────────────────────────────────┐      ┌────────────────────────────┐
│  Server   │  ⇄   │  Client                                          │  ⇄   │  Disk (SQLite)             │
│ (canonical)│      │                                                  │      │                            │
└───────────┘      │  ┌───────────────────┐  ┌─────────────────────┐ │      │ ┌────────────────────────┐ │
                   │  │  Y.Doc (CRDT)     │→ │ Query Engine        │ │      │ │ jsbao_storage.sqlite   │ │
                   │  │   in-memory CRDT  │  │  :memory: SQLite    │ │      │ │  ─ kv_store table ─    │ │
                   │  │   (records as     │  │  (per-model SQL     │ │      │ │   ─ store='yjs_docs'   │ │
                   │  │    YMap entries)  │  │   tables)           │ │      │ │   ─ store='kv'         │ │
                   │  └───────────────────┘  └─────────────────────┘ │      │ │   ─ store='meta'       │ │
                   │       │                          ▲              │      │ │                        │ │
                   │       └── update observer ───────┘              │      │ └────────────────────────┘ │
                   └─────────────────────────────────────────────────┘      │ ┌────────────────────────┐ │
                                                                            │ │ jsbao_storage.sqlite   │ │
                                                                            │ │  (auth namespace dir)  │ │
                                                                            │ │  ─ store='auth'        │ │
                                                                            │ └────────────────────────┘ │
                                                                            └────────────────────────────┘
```

## The four storage layers

### 1. Server — canonical truth

All authoritative state lives server-side. Every connected client gets a consistent view via WebSocket sync. The client never needs the network for *reads* once a doc is open and synced — but it *will* round-trip for things like `documents.list()`, `me.get()`, blob fetches, and direct record CRUD that doesn't go through Y.

### 2. Y.Doc — in-memory CRDT (your records, conceptually)

Each open document is a [Y.Doc](https://yjs.dev/) — a CRDT data structure living entirely in process memory. Records are stored as `YMap` entries: one root map per model (`tasks`, `todos`, `products`, …), keyed by record id, with each entry holding a sub-map of field values. Mutations go through Y transactions and emit update events that drive both the network sync and the query-engine projection.

This is what `TypedModel.findAll()` and `DynamicModel.findAll()` walk directly — no SQL involved, just YMap key iteration. It's fast because it's a hash-map lookup.

### 3. Query Engine — `:memory:` SQLite (your records, projected)

[`BaoModelQueryEngine`](../../../swift-client/Sources/JsBaoClient/Query/BaoModelQueryEngine.swift) maintains a real SQLite database with proper schemas, indexes, and foreign keys — but **entirely in RAM** (`sqlite3_open(":memory:")`). It's never written to disk.

Each [`DynamicModel`](../../../swift-client/Sources/JsBaoClient/Schema/DynamicModel.swift) (and the `TypedModel<T>` wrapping it) projects its YMap into a per-model SQL table (`tasks`, `todos`, etc.) and keeps it in sync via the Y.Doc update observer. Junction tables back stringset fields. Every column gets indexed.

This layer is what powers:
- `model.query(filter:)` — filtered SELECT with proper indexes
- `count`, `aggregate`, `queryPaged`, `findByUnique` — aggregations and joins
- `include: [...]` — relational lookups

In short: anything that would be a slow walk-and-filter against the YMap is a fast indexed query against this SQLite instead. The cost is RAM and a small write per mutation; the benefit is real SQL performance over typed data.

### 4. Persistence SQLite — `jsbao_storage.sqlite` (durability)

A single `kv_store(store, key, value, metadata, updated_at)` table on disk at `<Documents>/JsBaoClient/<appId>:<userId>/jsbao_storage.sqlite`. Schemaless from the table's perspective — values are blobs, namespaced by the `store` column.

The stores in use:
- `yjs_docs` — encoded Y.Doc CRDT bytes, one row per document. Binary, not human-readable.
- `meta` — `LocalMetadataEntry` per doc (title, permission, hasLocalCopy flag).
- `kv` — `KvCache` rows: hot REST/direct-record results cached for offline reads.
- `auth` — persisted JWT (lives in a *separate* `jsbao_storage.sqlite` file in `auth:<appId>:<namespace>/`, kept distinct so JWT churn never collides with offline data).

This layer is touched only at well-defined moments:
- **App start**: `documentManager.openDocument()` → `YjsSQLitePersistence.loadDocument()` reads the `yjs_docs` blob and applies it to a fresh in-memory Y.Doc, so first-paint reads see real data without waiting for the network.
- **After sync**: when `handleSyncComplete` fires, `persistDocumentToLocal()` writes the current Y.Doc state back as a single `INSERT OR REPLACE` into `yjs_docs`.
- **On close**: `closeDocument()` calls `persistDocumentToLocal()` once more before tearing down.

It is **not** queried during normal CRUD. Don't expect to see fast filtered queries served by this SQLite — it's a durable backup, not an index.

## When data moves between layers

| Trigger | Movement |
|---|---|
| App launches, user authed | `loadDocument()` reads from disk SQLite → applies CRDT to in-memory Y.Doc → query engine projects YMaps into `:memory:` tables. |
| Local mutation (`model.create/update/delete`) | YMap update inside transaction → update observer fires → query engine writes one row → emits local update for WebSocket sync. |
| Remote sync arrives | Update applied to Y.Doc under the remote-apply guard → query engine projects the change → `onDocumentSyncStateChanged(documentId:state:)` callback fires for the app when the state is `"synced"`. |
| Sync completes (`handleSyncComplete`) | `persistDocumentToLocal()` writes the full Y.Doc state to disk SQLite. |
| Document closes | One last `persistDocumentToLocal()`, then evict from in-memory structures. |
| `closeDocument(evictLocal: true)` | Skip the persist; instead, delete the disk row entirely. |
| App backgrounds (no special handling) | Whatever was last persisted on sync-complete is what survives. The next foreground will reload it. |

## Common confusions, resolved

> *"My SQLite tab shows `yjs_docs` rows but the value is a binary blob — where are my actual records?"*

The `yjs_docs` blob **is** all your records, encoded as a Y.Doc CRDT update. To read records as JSON, look at the Y.Doc layer (Documents tab in the inspector) or query the `:memory:` query engine (Memory SQL tab).

> *"Reloads are faster than the first load — is the disk SQLite serving query results?"*

No. The first load pays for: process startup, reading the `yjs_docs` blob, decoding the CRDT, building `:memory:` tables, opening the WebSocket, syncing with the server. Reloads within the same process keep the in-memory Y.Doc and query tables warm — the speedup is from skipping the cold-start work, not from disk-served queries. (Even on a true relaunch, what gets read off disk is one blob per doc, not query results.)

> *"Disk SQLite shows zero rows but my Documents tab shows records — bug?"*

Almost certainly a path mismatch. The disk-storage provider routes by namespace; if a single provider instance gets re-bound to a different namespace (e.g. JWT persistence using the same provider as offline data), writes go to the wrong file. The library now uses two separate `SQLiteStorageProvider` instances and refuses re-bind to a different path — but if you suspect the issue resurfaces, look for `auth:*` directories with surprisingly large WAL files.

> *"What's the relationship between Y.Doc and the query engine `:memory:` tables?"*

The Y.Doc is the source of truth in the client; the query engine is a derived index. The update observer keeps them in sync. If you mutate via `dynamic.upsert(...)`, the YMap is the actual write target; the engine's row write is a side-effect of the observer firing.

## Where to look for each thing in the inspector

| Layer | Inspector tab | What you see |
|---|---|---|
| Server | Documents (REST list), Tests | Doc list, request/response logs |
| Y.Doc (in-memory CRDT) | Documents | Materialized records as JSON, via `InspectableModelHost` |
| Query engine (`:memory:` SQLite) | Memory SQL | Per-model SQL tables with column schema and rows |
| Persistence (disk SQLite) | SQLite | Raw `kv_store` rows by store namespace |
| Live events | Events, Performance, Logs | Sync timing, update flow, log stream |

## Source pointers

- [`DocumentManager.openDocument`](../../../swift-client/Sources/JsBaoClient/Internal/DocumentManager.swift) — wires the persistence layer + sets up update observer.
- [`DocumentManager.persistDocumentToLocal`](../../../swift-client/Sources/JsBaoClient/Internal/DocumentManager.swift) — the disk write path.
- [`YjsSQLitePersistence`](../../../swift-client/Sources/JsBaoClient/Internal/DocumentManager.swift) — `loadDocument` / `saveDocument` for the `yjs_docs` store.
- [`SQLiteStorageProvider`](../../../swift-client/Sources/JsBaoClient/Storage/SQLiteStorageProvider.swift) — disk file open + `kv_store` schema.
- [`OfflineStore`](../../../swift-client/Sources/JsBaoClient/Internal/OfflineStore.swift) — the abstraction that namespaces metadata vs auth.
- [`BaoModelQueryEngine`](../../../swift-client/Sources/JsBaoClient/Query/BaoModelQueryEngine.swift) — `:memory:` SQLite, per-model tables, real `query/count/aggregate`.
- [`DynamicModel`](../../../swift-client/Sources/JsBaoClient/Schema/DynamicModel.swift) — wires Y.Doc ↔ query engine via update observer.
