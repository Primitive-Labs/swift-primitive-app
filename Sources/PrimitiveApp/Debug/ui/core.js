// Inspector factory base.
//
// Each tab lives in its own file (`ui/tabs/<name>.js`) and defines a
// factory function like `function overviewTab() { return { ...fragment };
// }`. InspectorHTML.swift concatenates those files after this one — so
// by the time `inspector()` runs, every `<name>Tab` factory is defined
// as a global function. Alpine calls `inspector()` to get the single
// `x-data` object; the merge loop below pulls each tab's state /
// getters / methods in via `Object.defineProperties` so property
// descriptors (notably getter accessors) survive the merge.
//
// What lives in this file:
//   - the shared state that belongs to no single tab: `conn`, `user`,
//     `docs`, `selectedDocId`, `models`, the live SSE `events` stream
//   - the lifecycle hook (`init`), polling loop, SSE wiring
//   - `fetchSnapshot`, `fetchModels`, `doAction` — called from every tab
//   - formatters reused across tabs (fmtTime, humanBytes, prettyJSON,
//     displayValue, eventColor, columnsFrom, logLevelColor, …)
//
// A tab file only declares its own state + getters + methods; once
// merged, `this.anyProperty` from any fragment reaches any other
// fragment on the final Alpine proxy.

/**
 * Tab factory names, in UI order. Must match the per-tab `<id>` in
 * `tabs:` below and the sections declared in `ui/tabs/*.html`.
 */
const __INSPECTOR_TAB_FACTORIES__ = [
  'overviewTab',
  'documentsTab',
  'testsTab',
  'databasesTab',
  'collectionsTab',
  'blobsTab',
  'performanceTab',
  'sqliteTab',
  'memdbTab',
  'eventsTab',
  'logsTab',
];

function inspector() {
  const base = __inspectorCore__();
  // Merge every tab factory that's been concatenated onto the global
  // scope after this file. Missing factories are skipped — that only
  // happens if the Swift loader's `tabOrder` doesn't include a tab, or
  // if someone renamed a file — and in both cases the skipped tab just
  // won't appear at runtime.
  for (const factoryName of __INSPECTOR_TAB_FACTORIES__) {
    const fn = (typeof globalThis !== 'undefined' ? globalThis : window)[factoryName];
    if (typeof fn !== 'function') continue;
    const fragment = fn();
    // Object.assign flattens getters to static values; defineProperties
    // + getOwnPropertyDescriptors preserves the accessor descriptor so
    // Alpine re-invokes the getter each time it's read.
    Object.defineProperties(base, Object.getOwnPropertyDescriptors(fragment));
  }
  return base;
}

/** Shared state + lifecycle + helpers. Separate from `inspector()`
 *  only so the merge loop above reads cleaner. */
function __inspectorCore__() {
  return {
    // ---- shared state ----
    tabs: [
      { id: 'overview',    label: 'Overview' },
      { id: 'documents',   label: 'Documents' },
      { id: 'tests',       label: 'Tests' },
      { id: 'databases',   label: 'Databases' },
      { id: 'collections', label: 'Collections' },
      { id: 'blobs',       label: 'Blobs' },
      { id: 'performance', label: 'Performance' },
      { id: 'sqlite',      label: 'SQLite (disk)' },
      { id: 'memdb',       label: 'Memory SQL' },
      { id: 'events',      label: 'Events' },
      { id: 'logs',        label: 'Logs' },
    ],
    activeTab: localStorage.getItem('primitive-inspector-tab') || 'overview',

    conn: {}, user: {},
    docs: [], selectedDocId: null,
    // Cascade-only docs: every doc the user reaches via collection
    // membership but doesn't have a direct permission grant on (so
    // `documents.list()` — which powers `docs` — never returns them).
    // Loaded lazily on Documents tab entry from `/api/cascade-docs`.
    // Each entry: { id, title, tags, permission, collectionIds }.
    cascadeDocs: [], cascadeDocsLoading: false,
    // Models-for-selectedDoc cache used by Documents' Records panel AND by
    // Performance to annotate sync events. Populated by `fetchModels`.
    models: [],

    // Live event stream (SSE from /api/events). Events are always
    // captured regardless of which tab is active; the Events tab is just
    // the primary viewer + filter.
    events: [], eventsPaused: false, eventAutoScroll: true,
    sseStatus: 'connecting',
    // Dedup set for the SSE reconnect race: EventSource auto-reconnects
    // on any network blip, and the server's `init` replays the full
    // buffered tail (no Last-Event-ID support). Without this, events
    // the client already has get appended again — the Perf tab
    // especially shows duplicates. Plain `Set` (Alpine doesn't wrap
    // it), pruned alongside the `events` ring in `pushEvent`.
    _seenEventKeys: new Set(),

    // ---- lifecycle ----
    async init() {
      this.$watch('activeTab', v => localStorage.setItem('primitive-inspector-tab', v));
      // Tab-specific loaders fire on tab entry. Each tab module declares
      // its own loader (loadPerf, loadTests, etc.); we route from here
      // using optional-chaining so unknown/missing loaders are silent.
      this.$watch('activeTab', v => {
        // Performance tab is fed live from the SSE event stream (see
        // tabs/performance.js) — no tab-activation fetch needed.
        if (v === 'tests')       this.loadTests?.();
        if (v === 'databases')   this.loadDatabases?.();
        if (v === 'collections') this.loadCollections?.();
        if (v === 'documents')   this.loadCascadeDocs?.();
        if (v === 'blobs')       this.loadBlobs?.();
        if (v === 'logs')        this.loadLogs?.();
        if (v === 'memdb')       this.reloadMemDB?.();
      });
      // Keep Logs tab lightly self-refreshing so failed actions show up immediately.
      setInterval(() => { if (this.activeTab === 'logs' && this.logsAutoRefresh) this.loadLogs?.(); }, 1500);
      // Memory SQL polls while active — `:memory:` content can change on
      // every CRUD op, and there's no SSE signal that maps cleanly to it.
      setInterval(() => { if (this.activeTab === 'memdb' && this.memdbPolling) this.reloadMemDB?.({ silent: true }); }, 2000);
      this.$watch('selectedDocId', () => {
        if (this.activeTab === 'blobs') this.loadBlobs?.();
      });

      await this.fetchSnapshot();
      // Polling loop for bulk state. Cheap; the server turns a fresh snapshot around in <5ms.
      setInterval(() => this.fetchSnapshot(), 2000);
      this.connectEvents();
    },

    // ---- snapshot + models ----
    async fetchSnapshot() {
      try {
        const r = await fetch('/api/snapshot', { cache: 'no-store' });
        if (!r.ok) return;
        const snap = await r.json();
        this.conn = snap.connection || {};
        this.user = snap.user || {};
        this.docs = snap.documents || [];
        this.selectedDocId = this.selectedDocId || snap.selectedDocId || null;
        this.sqlitePath = snap.storage?.path || '';
        this.sqliteStores = snap.storage?.stores || [];
        if (!this.activeStore && this.sqliteStores.length) this.selectStore?.(this.sqliteStores[0].name);
        if (this.conn.appId) document.title = 'Inspector · ' + this.conn.appId;
        // Lazy: pull models whenever selection changes or on first paint.
        if (!this.models.length) this.fetchModels();
      } catch { /* snapshot is best-effort; transient network errors are expected */ }
    },
    async fetchModels() {
      try {
        const r = await fetch('/api/models', { cache: 'no-store' });
        if (!r.ok) return;
        const payload = await r.json();
        this.models = payload.models || [];
      } catch { /* ignore */ }
    },

    // ---- universal action helper ----
    // POSTs to /api/action/{name}. Surfaces server error details (HTTP
    // status, server body, JsBao code/details) via `alert()` and flips
    // to the Logs tab so the next look finds the same message with more
    // surrounding context.
    async doAction(name, body) {
      const payload = body || {};
      try {
        const r = await fetch('/api/action/' + name, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
        const res = await r.json();
        if (!res.ok) {
          let msg = 'Action failed: ' + (res.error || 'unknown');
          if (res.status) msg += ' (HTTP ' + res.status + ')';
          if (res.code)   msg += ' [' + res.code + ']';
          if (res.serverBody) msg += '\n\nServer said:\n' + res.serverBody;
          if (res.details && Object.keys(res.details).length) {
            msg += '\n\nDetails:\n' + JSON.stringify(res.details, null, 2);
          }
          alert(msg);
          this.loadLogs?.();
        }
        return res;
      } catch (e) {
        alert('Action error: ' + e.message);
        return { ok: false };
      }
    },

    // ---- SSE (fed continuously, consumed by Events + Overview tail) ----
    connectEvents() {
      this.sseStatus = 'connecting';
      const es = new EventSource('/api/events');
      es.addEventListener('open',  () => { this.sseStatus = 'connected'; });
      es.addEventListener('error', () => { this.sseStatus = 'reconnecting'; });
      es.addEventListener('init',  (ev) => {
        try { JSON.parse(ev.data).forEach(e => this.pushEvent(e, true)); } catch { /* ignore */ }
      });
      es.addEventListener('event', (ev) => {
        try { this.pushEvent(JSON.parse(ev.data), false); } catch { /* ignore */ }
      });
    },
    pushEvent(e, fromReplay) {
      if (this.eventsPaused && !fromReplay) return;
      // Dedup: skip anything we've already ingested. The server's
      // ts (ms) + type + documentId tuple is stable per event, so
      // replay-after-reconnect events match and get dropped.
      const key = this._eventKey(e);
      if (this._seenEventKeys.has(key)) return;
      this._seenEventKeys.add(key);
      this.events.push(e);
      if (this.events.length > 1000) {
        // Keep the dedup set in sync with the ring so it doesn't grow
        // unbounded. Dropping an event's key here means a *much-later*
        // reconnect could theoretically re-add it, but in practice the
        // server's own ring is also bounded (500 entries); we won't
        // replay events that old anyway.
        const dropped = this.events.splice(0, this.events.length - 1000);
        for (const d of dropped) this._seenEventKeys.delete(this._eventKey(d));
      }
      if (this.eventAutoScroll && this.activeTab === 'events') {
        this.$nextTick(() => { const el = this.$refs.evLog; if (el) el.scrollTop = el.scrollHeight; });
      }
    },
    _eventKey(e) {
      // Concat, not JSON.stringify: good enough for server-emitted
      // events (ts is unique-enough at ms precision, and type +
      // documentId covers the few same-ms collisions that could happen
      // when several phases fire for different docs in the same ms).
      return (e.ts || 0) + ':' + (e.type || '') + ':' + (e.documentId || '');
    },

    // ---- shared formatters / helpers ----
    fmtTime(ts)      { const d = new Date(ts || Date.now()); return d.toTimeString().slice(0, 8) + '.' + String(d.getMilliseconds()).padStart(3, '0'); },
    fmtTimeShort(ts) { const d = new Date(ts || Date.now()); return d.toTimeString().slice(0, 8); },
    yn(v) { return v === true ? 'yes' : v === false ? 'no' : '—'; },
    prettyJSON(v) {
      try {
        const o = typeof v === 'string' ? JSON.parse(v) : v;
        return JSON.stringify(o, null, 2);
      } catch { return String(v); }
    },
    displayValue(v) {
      if (v === null || v === undefined) return '—';
      if (typeof v === 'object') return JSON.stringify(v);
      return String(v);
    },
    compactBody(e) {
      const clean = Object.assign({}, e);
      delete clean.ts;
      delete clean.type;
      return Object.keys(clean).length ? JSON.stringify(clean) : '';
    },
    eventColor(type) {
      if (type === 'status' || type === 'networkMode') return 'var(--accent)';
      if (type === 'sync') return 'var(--green)';
      if (type === 'remoteUpdate') return 'var(--yellow)';
      if (type === 'documentLoaded' || type === 'documentClosed') return 'var(--blue)';
      if (type && (type.includes('Failed') || type === 'pendingCreateFailed')) return 'var(--red)';
      if (type === 'permission') return 'var(--primary)';
      return 'var(--violet)';
    },
    logLevelColor(level) {
      if (level === 'error') return 'var(--red)';
      if (level === 'warn')  return 'var(--yellow)';
      return 'var(--accent)';
    },
    humanBytes(n) {
      if (n == null || isNaN(n)) return '—';
      if (n < 1024) return n + ' B';
      if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
      if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' MB';
      return (n / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
    },
    // Union of every key seen across `rows`. Stable order so column
    // headers don't jitter between renders: `id` (or `_id`) first, rest
    // alphabetical. Used by the Records tables (Documents, Databases).
    columnsFrom(rows) {
      const set = new Set();
      for (const r of rows || []) {
        if (r && typeof r === 'object') {
          for (const k of Object.keys(r)) set.add(k);
        }
      }
      const cols = Array.from(set);
      cols.sort((a, b) => {
        const pri = x => x === 'id' ? 0 : x === '_id' ? 1 : 2;
        const pa = pri(a);
        const pb = pri(b);
        if (pa !== pb) return pa - pb;
        return a.localeCompare(b);
      });
      return cols;
    },
  };
}
