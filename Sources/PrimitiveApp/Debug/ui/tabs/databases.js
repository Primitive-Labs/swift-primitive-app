// ==== Databases tab ====
// Two surfaces, side by side:
//   1. Models (primary) — direct `records/*` path. Generic CRUD on rows,
//      bypassing CEL. Server-gated to app admins + db owners, so a
//      401/403 auto-expands the Operations fallback with a nudge.
//   2. Registered operations (secondary, collapsible) — the
//      production path. CEL-gated, app-defined. Anyone with access
//      to the database can run them.
// Either path works on its own, so non-owners can still interact
// with a database via its registered operations.

function databasesTab() {
  return {
    databases: [], databasesError: '',
    selectedDatabaseId: null,
    dbFilter: '',
    showNewDbForm: false,
    newDb: { title: '', databaseType: '' },
    newDbError: '',
    newDbSubmitting: false,

    // Models / records (direct `records/*` path)
    dbModels: [], dbModelsError: '', dbModelsLoading: false,
    dbActiveModelName: '',
    dbModelFields: [],                     // from /records/describe, shapes the new-record form
    dbModelRows: [], dbRowsLoading: false,
    dbRecordError: '',                     // set when the records path fails (e.g. 403 for non-admins)
    dbShowNewRowForm: false,
    dbNewRow: {},                          // field → value (typed by kind from describe)
    dbNewRowJson: '',                      // freeform JSON for schemaless models
    dbNewRowError: '',
    dbNewRowSubmitting: false,

    // Registered operations (CEL-gated path)
    dbOperations: [], dbOperationsError: '',
    dbOperationsLoading: false,
    showDbOperations: false,
    activeOperationName: '',
    operationRunning: false,
    operationRows: [],
    operationResult: null,
    operationError: '',

    // ---- derived ----
    get filteredDatabases() {
      const q = this.dbFilter.toLowerCase().trim();
      if (!q) return this.databases;
      return this.databases.filter(db => {
        const name = String(db.title || db.name || '').toLowerCase();
        const id   = String(db.databaseId || db.id || '').toLowerCase();
        const type = String(db.databaseType || '').toLowerCase();
        return name.includes(q) || id.includes(q) || type.includes(q);
      });
    },
    get selectedDatabase() {
      if (!this.selectedDatabaseId) return null;
      return this.databases.find(db => (db.databaseId || db.id) === this.selectedDatabaseId) || null;
    },
    // Normalize the DO's describe shape (`{ field_name, inferred_type }`)
    // to the same `{ name, kind, optional }` shape the Records tab uses,
    // so the new-record form template can kind-dispatch the same way.
    // Drops `id` (auto-generated) and internal `_`-prefixed fields.
    get dbModelEditableFields() {
      const out = [];
      for (const f of (this.dbModelFields || [])) {
        const name = f.name || f.field_name;
        if (!name || name === 'id' || name.startsWith('_')) continue;
        const raw = (f.kind || f.inferred_type || f.type || 'string').toLowerCase();
        let kind = 'string';
        if (raw === 'boolean' || raw === 'bool')       kind = 'boolean';
        else if (raw === 'number' || raw === 'integer' || raw === 'int' || raw === 'float' || raw === 'double') kind = 'number';
        else if (raw === 'stringset')                   kind = 'stringset';
        else if (raw === 'json' || raw === 'object' || raw === 'array') kind = 'json';
        else if (raw === 'date' || raw === 'datetime' || raw === 'timestamp') kind = 'date';
        out.push({ name, kind, optional: true });
      }
      return out;
    },
    get dbModelColumns()   { return this.columnsFrom(this.dbModelRows); },
    get operationColumns() { return this.columnsFrom(this.operationRows); },

    // ---- database CRUD (the parent entity) ----
    async loadDatabases() {
      try {
        const r = await fetch('/api/databases', { cache: 'no-store' });
        const p = await r.json();
        this.databases = p.items || [];
        this.databasesError = p.error || '';
      } catch (e) { this.databases = []; this.databasesError = String(e); }
    },
    selectDb(id) {
      if (this.selectedDatabaseId === id) return;
      this.selectedDatabaseId = id;
      // Clear stale state from the previously-selected db.
      this.dbModels = [];
      this.dbModelsError = '';
      this.dbActiveModelName = '';
      this.dbModelFields = [];
      this.dbModelRows = [];
      this.dbRecordError = '';
      this.dbShowNewRowForm = false;
      this.dbOperations = [];
      this.dbOperationsError = '';
      this.activeOperationName = '';
      this.operationRows = [];
      this.operationResult = null;
      this.operationError = '';
      // Both surfaces load in parallel. Operations stay collapsed unless
      // the records path fails (loadDbModelRows 403 handler flips it).
      this.loadDbModels();
      this.loadDbOperations();
    },
    toggleNewDbForm() {
      if (this.showNewDbForm) {
        this.showNewDbForm = false;
        return;
      }
      this.newDb = { title: '', databaseType: '' };
      this.newDbError = '';
      this.showNewDbForm = true;
    },
    async submitNewDb() {
      if (!this.newDb.title || !this.newDb.title.trim()) {
        this.newDbError = 'title is required';
        return;
      }
      this.newDbSubmitting = true;
      try {
        const res = await this.doAction('db/create', {
          title: this.newDb.title.trim(),
          databaseType: (this.newDb.databaseType || '').trim(),
        });
        if (res.ok) {
          this.showNewDbForm = false;
          this.newDb = { title: '', databaseType: '' };
          await this.loadDatabases();
          // Pre-select so the user lands on the detail view without a second click.
          if (res.databaseId) this.selectedDatabaseId = res.databaseId;
        } else if (res.error) {
          this.newDbError = res.error;
        }
      } finally {
        this.newDbSubmitting = false;
      }
    },
    async renameDb() {
      if (!this.selectedDatabase) return;
      const current = this.selectedDatabase.title || this.selectedDatabase.name || '';
      const title = prompt('New title?', current);
      if (title === null || title === current) return;
      const id = this.selectedDatabase.databaseId || this.selectedDatabase.id;
      const res = await this.doAction('db/rename', { databaseId: id, title });
      if (res.ok) await this.loadDatabases();
    },
    async deleteDb() {
      if (!this.selectedDatabase) return;
      const name = this.selectedDatabase.title || this.selectedDatabase.name
                || this.selectedDatabase.databaseId || this.selectedDatabase.id;
      if (!confirm('Delete "' + name + '"? This cannot be undone.')) return;
      const id = this.selectedDatabase.databaseId || this.selectedDatabase.id;
      const res = await this.doAction('db/delete', { databaseId: id });
      if (res.ok) {
        this.selectedDatabaseId = null;
        await this.loadDatabases();
      }
    },

    // ---- models / records (direct `records/*` path) ----
    async loadDbModels() {
      if (!this.selectedDatabaseId) return;
      this.dbModelsLoading = true;
      this.dbModelsError = '';
      try {
        const r = await fetch('/api/db/models?databaseId=' + encodeURIComponent(this.selectedDatabaseId), { cache: 'no-store' });
        const p = await r.json();
        this.dbModels = p.models || [];
        this.dbModelsError = p.error || '';
      } catch (e) {
        this.dbModels = [];
        this.dbModelsError = String(e);
      } finally {
        this.dbModelsLoading = false;
      }
    },
    async selectDbModel(name) {
      this.dbActiveModelName = name;
      this.dbModelRows = [];
      this.dbRecordError = '';
      this.dbShowNewRowForm = false;
      this.dbNewRow = {};
      this.dbNewRowJson = '';
      await Promise.all([this.loadDbModelFields(), this.loadDbModelRows()]);
    },
    async loadDbModelFields() {
      if (!this.selectedDatabaseId || !this.dbActiveModelName) {
        this.dbModelFields = [];
        return;
      }
      try {
        const r = await fetch(
          '/api/db/describe?databaseId=' + encodeURIComponent(this.selectedDatabaseId)
          + '&modelName=' + encodeURIComponent(this.dbActiveModelName),
          { cache: 'no-store' }
        );
        const p = await r.json();
        this.dbModelFields = p.fields || [];
      } catch {
        this.dbModelFields = [];
      }
    },
    async loadDbModelRows() {
      if (!this.selectedDatabaseId || !this.dbActiveModelName) return;
      this.dbRowsLoading = true;
      this.dbRecordError = '';
      const res = await this.doAction('db/records/query', {
        databaseId: this.selectedDatabaseId,
        modelName: this.dbActiveModelName,
      });
      this.dbRowsLoading = false;
      if (res.ok) {
        this.dbModelRows = Array.isArray(res.rows) ? res.rows : [];
        return;
      }
      // Auto-expand the operations fallback on permission failures so the
      // user sees an actionable alternative without hunting for it.
      this.dbModelRows = [];
      const status = res.status;
      const isPermError = status === 401 || status === 403;
      if (isPermError) {
        this.showDbOperations = true;
        this.dbRecordError =
          'This database\'s raw records can only be browsed by an app admin/owner or a database manager — that\'s the server-side gate on the direct records routes.\n\n'
          + 'Use the Registered operations section below to run a CEL-gated operation instead.\n\n'
          + (res.error ? 'Server said: ' + res.error : '');
      } else {
        this.dbRecordError = res.error || 'failed to load rows';
      }
    },
    toggleDbNewRowForm() {
      if (this.dbShowNewRowForm) { this.dbShowNewRowForm = false; return; }
      this.dbNewRow = {};
      this.dbNewRowError = '';
      for (const f of this.dbModelEditableFields) {
        this.dbNewRow[f.name] = f.kind === 'boolean' ? false : '';
      }
      this.dbShowNewRowForm = true;
    },
    async submitDbNewRow() {
      if (!this.selectedDatabaseId || !this.dbActiveModelName) return;
      this.dbNewRowError = '';
      // Build the payload. Without a described schema, fall back to the
      // raw-JSON textarea.
      let data;
      const fields = this.dbModelEditableFields;
      if (fields.length) {
        data = {};
        for (const f of fields) {
          const raw = this.dbNewRow[f.name];
          // Empty-ish values fall through to server defaults / auto-assign.
          const isEmpty = raw === undefined || raw === null || raw === ''
                          || (Array.isArray(raw) && raw.length === 0);
          if (isEmpty && f.kind !== 'boolean') continue;
          // Kind-specific coercion matches the Records tab.
          if (f.kind === 'stringset' && typeof raw === 'string') {
            data[f.name] = raw.split(',').map(s => s.trim()).filter(Boolean);
          } else if (f.kind === 'json' && typeof raw === 'string') {
            try {
              data[f.name] = JSON.parse(raw);
            } catch (e) {
              this.dbNewRowError = f.name + ': invalid JSON (' + e.message + ')';
              return;
            }
          } else {
            data[f.name] = raw;
          }
        }
      } else {
        const text = (this.dbNewRowJson || '').trim();
        if (!text) { this.dbNewRowError = 'JSON body required'; return; }
        try { data = JSON.parse(text); }
        catch (e) { this.dbNewRowError = 'invalid JSON: ' + e.message; return; }
      }
      // Let the server mint the id via our Swift-side ULID fallback. If
      // the raw-JSON body supplied `id`, keep it.
      let suppliedId;
      if (data && typeof data === 'object' && typeof data.id === 'string' && data.id) {
        suppliedId = data.id;
        delete data.id;
      }
      this.dbNewRowSubmitting = true;
      const payload = {
        databaseId: this.selectedDatabaseId,
        modelName: this.dbActiveModelName,
        data,
      };
      if (suppliedId) payload.id = suppliedId;
      const res = await this.doAction('db/records/create', payload);
      this.dbNewRowSubmitting = false;
      if (res.ok) {
        this.dbShowNewRowForm = false;
        this.dbNewRow = {};
        this.dbNewRowJson = '';
        await this.loadDbModelRows();
      } else if (res.error) {
        this.dbNewRowError = res.error;
      }
    },
    async deleteDbRow(id) {
      if (!id || !this.selectedDatabaseId || !this.dbActiveModelName) return;
      if (!confirm('Delete record ' + id + '?')) return;
      const res = await this.doAction('db/records/delete', {
        databaseId: this.selectedDatabaseId,
        modelName: this.dbActiveModelName,
        id,
      });
      if (res.ok) await this.loadDbModelRows();
    },

    // ---- registered operations (CEL-gated path) ----
    async loadDbOperations() {
      if (!this.selectedDatabaseId) { this.dbOperations = []; return; }
      this.dbOperationsLoading = true;
      try {
        const r = await fetch('/api/db/operations?databaseId=' + encodeURIComponent(this.selectedDatabaseId), { cache: 'no-store' });
        const p = await r.json();
        this.dbOperations = p.items || [];
        this.dbOperationsError = p.error || '';
      } catch (e) {
        this.dbOperations = [];
        this.dbOperationsError = String(e);
      } finally {
        this.dbOperationsLoading = false;
      }
    },
    async runOperation(name) {
      if (!this.selectedDatabaseId || !name) return;
      this.activeOperationName = name;
      this.operationRunning = true;
      this.operationError = '';
      this.operationRows = [];
      this.operationResult = null;
      const res = await this.doAction('db/execute', {
        databaseId: this.selectedDatabaseId,
        name,
      });
      if (res.ok) {
        this.operationRows = Array.isArray(res.rows) ? res.rows : [];
        this.operationResult = res.result;
      } else {
        this.operationError = res.error || 'execution failed';
      }
      this.operationRunning = false;
    },
  };
}
