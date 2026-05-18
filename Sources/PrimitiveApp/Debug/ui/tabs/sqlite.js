// ==== SQLite tab ====
// Read-only browser over the client's local kv_store. Stores + their
// row counts come from `/api/snapshot` (populated by
// `InspectorSQLiteReader.listStores`) so no extra fetch on tab enter.
// `/api/sqlite/diag` powers the diagnostics toggle: it reports which
// filesystem roots were scanned, which `appId:userId` subdirs
// matched, and which jsbao_storage.sqlite file was resolved.

function sqliteTab() {
  return {
    sqlitePath: '', sqliteStores: [],
    activeStore: null, storeRows: [],
    showSqliteDiag: false,
    sqliteDiag: null,

    // ---- actions ----
    toggleSqliteDiag() { this.showSqliteDiag = !this.showSqliteDiag; },
    async loadSqliteDiag() {
      try {
        const r = await fetch('/api/sqlite/diag', { cache: 'no-store' });
        this.sqliteDiag = await r.json();
      } catch (e) {
        this.sqliteDiag = { error: String(e) };
      }
    },
    async selectStore(name) {
      this.activeStore = name;
      try {
        const r = await fetch('/api/sqlite/store/' + encodeURIComponent(name) + '?limit=200', { cache: 'no-store' });
        this.storeRows = await r.json();
      } catch { this.storeRows = []; }
    },
  };
}
