// ==== Memory SQL tab ====
// Read-only browser + ad-hoc query runner over the JsBaoClient's `:memory:`
// query engine (`BaoModelQueryEngine`). One real SQLite database per
// `DynamicModel`, lives entirely in RAM, kept in sync with the Y.Doc via
// the update observer.
//
// Endpoints used:
//   GET  /api/memdb                            → catalog (models, tables, row counts)
//   GET  /api/memdb/columns?model&documentId&table → PRAGMA table_info
//   GET  /api/memdb/rows?model&documentId&table&limit → SELECT * FROM table LIMIT N
//   POST /api/action/memdb/exec                → arbitrary SELECT/PRAGMA/WITH
//   POST /api/action/record/create             → CRUD via DynamicModel (Y.Doc → engine)
//   POST /api/action/record/delete             → CRUD via DynamicModel (Y.Doc → engine)
//
// Why CRUD goes through `record/...` and not direct SQL: the engine is a
// projection of the Y.Doc; direct DML would desync. The server enforces
// SELECT/PRAGMA/WITH-only on `memdb/exec` for the same reason.
//
// See docs/data-flow.md for how this layer relates to disk SQLite.

function memdbTab() {
  return {
    // ---- catalog state ----
    memdbModels: [],
    activeMemDBKey: null,
    activeMemDBModel: null,
    activeMemDBTable: null,
    memdbColumns: [],
    memdbRows: [],

    // ---- polling ----
    // Lifecycle: core.js's $watch('activeTab') calls reloadMemDB() on tab
    // entry, and a 2s interval in core.js calls reloadMemDB({silent:true})
    // while the tab is active and `memdbPolling` is true. This factory
    // never calls `init()` itself — that's reserved for core.js (the
    // factory merge would clobber it).
    memdbPolling: true,

    // ---- custom query ----
    memdbQuery: '',
    memdbQueryResults: null,   // { rows: [...], columns: [...] } | null
    memdbQueryError: null,

    // ---- create-row modal ----
    memdbCreateOpen: false,
    memdbCreateValues: {},
    memdbCreateError: null,
    memdbCreating: false,

    // ---- catalog actions ----
    async reloadMemDB(opts = {}) {
      try {
        const r = await fetch('/api/memdb', { cache: 'no-store' });
        const data = await r.json();
        const next = data.models || [];
        this.memdbModels = next;

        // Re-resolve active model + table (the ones the user is looking at).
        if (this.activeMemDBKey) {
          const found = next.find(
            m => (m.model + ':' + m.documentId) === this.activeMemDBKey
          );
          if (found) {
            this.activeMemDBModel = found;
            // Auto-pick a table if we don't have one (first load) or the
            // current table no longer exists.
            const stillThere = found.tables.some(t => t.name === this.activeMemDBTable);
            if (!stillThere) {
              const main = found.tables.find(t => t.name === found.mainTable) || found.tables[0];
              this.activeMemDBTable = main ? main.name : null;
              if (this.activeMemDBTable) await this.loadMemDBTable(this.activeMemDBTable);
              else { this.memdbColumns = []; this.memdbRows = []; }
            } else if (this.activeMemDBTable && !this.memdbQueryResults) {
              await this.loadMemDBTable(this.activeMemDBTable, opts);
            }
          } else {
            // Active model dropped (doc closed). Auto-pick the first.
            if (next.length) this.selectMemDBModel(next[0]);
            else {
              this.activeMemDBModel = null;
              this.activeMemDBTable = null;
              this.memdbColumns = [];
              this.memdbRows = [];
            }
          }
        } else if (next.length) {
          // First-time load + we have at least one model: auto-select.
          this.selectMemDBModel(next[0]);
        }
      } catch {
        if (!opts.silent) {
          this.memdbModels = [];
        }
      }
    },

    selectMemDBModel(m) {
      this.activeMemDBKey = m.model + ':' + m.documentId;
      this.activeMemDBModel = m;
      this.memdbColumns = [];
      this.memdbRows = [];
      // Clear any custom query when switching models so the user sees
      // the default table.
      this.clearMemDBQuery();
      const main = m.tables.find(t => t.name === m.mainTable) || m.tables[0];
      if (main) this.selectMemDBTable(main.name);
      else this.activeMemDBTable = null;
    },

    async selectMemDBTable(name) {
      this.activeMemDBTable = name;
      this.clearMemDBQuery();
      await this.loadMemDBTable(name);
    },

    async loadMemDBTable(name, opts = {}) {
      if (!this.activeMemDBModel) return;
      const m = this.activeMemDBModel;
      const qs = new URLSearchParams({
        model: m.model,
        documentId: m.documentId,
        table: name,
      });
      try {
        const [colsR, rowsR] = await Promise.all([
          fetch('/api/memdb/columns?' + qs.toString(), { cache: 'no-store' }),
          fetch('/api/memdb/rows?' + qs.toString() + '&limit=200', { cache: 'no-store' }),
        ]);
        this.memdbColumns = await colsR.json();
        this.memdbRows = await rowsR.json();
      } catch {
        if (!opts.silent) {
          this.memdbColumns = [];
          this.memdbRows = [];
        }
      }
    },

    // What the table view actually renders. Wraps `memdbRows` so we can
    // inject derived state without mutating the fetched array.
    get memdbDisplayRows() {
      return this.memdbRows;
    },

    // ---- custom query ----

    async runMemDBQuery() {
      const sql = this.memdbQuery.trim();
      if (!sql || !this.activeMemDBModel) return;
      this.memdbQueryError = null;
      this.memdbQueryResults = null;
      const result = await this.doAction('memdb/exec', {
        model: this.activeMemDBModel.model,
        documentId: this.activeMemDBModel.documentId,
        sql,
      });
      if (result && result.ok) {
        this.memdbQueryResults = {
          rows: result.rows || [],
          columns: result.columns || [],
        };
      } else {
        this.memdbQueryError = result ? (result.error || 'query failed') : 'query failed';
      }
    },

    clearMemDBQuery() {
      this.memdbQueryResults = null;
      this.memdbQueryError = null;
    },

    // ---- CRUD ----

    // Whether the inspector knows how to delete from this model. The
    // catalog payload doesn't carry that flag, so cross-reference the
    // models entry in the Documents tab's snapshot, which does.
    get canMemDBDelete() {
      if (!this.activeMemDBModel) return false;
      const meta = (this.models || []).find(
        x => x.name === this.activeMemDBModel.model && x.documentId === this.activeMemDBModel.documentId
      );
      return meta ? !meta.readOnly : false;
    },

    get canMemDBCreate() {
      if (!this.activeMemDBModel) return false;
      const meta = (this.models || []).find(
        x => x.name === this.activeMemDBModel.model && x.documentId === this.activeMemDBModel.documentId
      );
      return meta ? !!meta.canCreate : false;
    },

    // The model's field list as exposed by the InspectableModel snapshot.
    // Used to seed the create-row modal so the inspector's typed form has
    // the right field/kind for each input. Returns [] for junction tables.
    get memdbCreateFields() {
      if (!this.activeMemDBModel) return [];
      const meta = (this.models || []).find(
        x => x.name === this.activeMemDBModel.model && x.documentId === this.activeMemDBModel.documentId
      );
      // Drop `id` — DynamicModel.create generates ULIDs when absent.
      return (meta?.fields || []).filter(f => f.name !== 'id');
    },

    openMemDBCreate() {
      this.memdbCreateValues = {};
      for (const f of this.memdbCreateFields) {
        this.memdbCreateValues[f.name] = f.kind === 'json' ? '{}' : '';
      }
      this.memdbCreateError = null;
      this.memdbCreateOpen = true;
    },

    async submitMemDBCreate() {
      if (!this.activeMemDBModel || this.memdbCreating) return;
      this.memdbCreating = true;
      this.memdbCreateError = null;
      try {
        const values = {};
        for (const f of this.memdbCreateFields) {
          const raw = this.memdbCreateValues[f.name];
          if (raw === '' || raw === null || raw === undefined) {
            // Leave unset for optional fields; for required the server-side
            // validator will reject it with a useful message.
            continue;
          }
          if (f.kind === 'number') {
            const n = Number(raw);
            if (Number.isFinite(n)) values[f.name] = n;
          } else if (f.kind === 'boolean') {
            values[f.name] = raw === 'true';
          } else if (f.kind === 'json') {
            try {
              values[f.name] = JSON.parse(raw);
            } catch (e) {
              throw new Error(`invalid JSON for ${f.name}: ${e.message}`);
            }
          } else {
            values[f.name] = String(raw);
          }
        }
        const result = await this.doAction('record/create', {
          model: this.activeMemDBModel.model,
          documentId: this.activeMemDBModel.documentId,
          values,
        });
        if (result && result.ok) {
          this.memdbCreateOpen = false;
          await this.reloadMemDB({ silent: false });
        } else {
          this.memdbCreateError = result ? (result.error || 'create failed') : 'create failed';
        }
      } catch (e) {
        this.memdbCreateError = String(e.message || e);
      } finally {
        this.memdbCreating = false;
      }
    },

    async deleteMemDBRow(row) {
      if (!this.activeMemDBModel) return;
      if (!row || !row.id) return;
      const ok = window.confirm(`Delete ${this.activeMemDBModel.model}/${row.id}?`);
      if (!ok) return;
      const result = await this.doAction('record/delete', {
        model: this.activeMemDBModel.model,
        documentId: this.activeMemDBModel.documentId,
        id: row.id,
      });
      if (result && result.ok) {
        await this.reloadMemDB({ silent: false });
      }
    },

    // ---- formatting helpers ----

    memdbCellDisplay(v) {
      if (v == null) return 'NULL';
      if (typeof v === 'string') return v;
      if (typeof v === 'number' || typeof v === 'boolean') return String(v);
      try { return JSON.stringify(v); } catch { return String(v); }
    },

    // Full value for hover-title. Same as display but never truncated.
    memdbCellFull(v) {
      if (v == null) return 'NULL';
      if (typeof v === 'string') return v;
      try { return JSON.stringify(v, null, 2); } catch { return String(v); }
    },

    // Stable row identity for Alpine's :key. SQL rows usually have an `id`;
    // junction tables don't, so fall back to row index from the iteration.
    memdbRowKey(r, i) {
      if (r && typeof r.id === 'string') return r.id;
      return String(i);
    },
  };
}
