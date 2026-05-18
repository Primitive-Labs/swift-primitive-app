// ==== Documents tab ====
// Left column: doc list + filter + doc CRUD.
// Middle column: "Records" browser — one model picker + table +
// new-record form. Reads from `models` (core) populated by
// `fetchModels()` against /api/models.
//
// `selectDoc(id)` auto-opens the doc server-side (via doc/open, which
// awaits the full sync + onDocumentOpened hook) so by the time we
// refetch models, the host's InspectableModelHost has rebound them
// to the newly-active doc.

function documentsTab() {
  return {
    docFilter: '',
    // Non-null while an auto-open triggered by sidebar click is in flight.
    // Drives the "opening..." placeholder in the Records tab.
    openingDocId: null,

    // Records sub-panel state
    activeModelName: '',
    records: [], recordFilter: '',
    recordSort: { field: null, dir: 1 },

    // New-record form
    showNewRecordForm: false,
    newRecord: {},
    newRecordError: '',
    newRecordSubmitting: false,

    // Filter for the cascade-docs sub-section. Reuses the same
    // `docFilter` text so a single search box covers both lists.
    get filteredCascadeDocs() {
      const q = this.docFilter.toLowerCase().trim();
      const sorted = (this.cascadeDocs || []).slice().sort((a, b) =>
        (a.title || a.id).localeCompare(b.title || b.id)
      );
      if (!q) return sorted;
      return sorted.filter(d =>
        (d.title || '').toLowerCase().includes(q) ||
        d.id.toLowerCase().includes(q)
      );
    },

    async loadCascadeDocs() {
      this.cascadeDocsLoading = true;
      try {
        const r = await fetch('/api/cascade-docs', { cache: 'no-store' });
        if (!r.ok) return;
        const payload = await r.json();
        this.cascadeDocs = payload.items || [];
      } catch { /* best-effort */ } finally {
        this.cascadeDocsLoading = false;
      }
    },

    // ---- derived ----
    get docCounts() {
      const open = this.docs.filter(d => d.isOpen).length;
      const pending = this.docs.filter(d => d.isPendingCreate).length;
      return { total: this.docs.length, open, pending };
    },
    get filteredDocs() {
      const q = this.docFilter.toLowerCase().trim();
      const sorted = this.docs.slice().sort((a, b) => {
        if (a.isOpen !== b.isOpen) return a.isOpen ? -1 : 1;
        return (a.title || a.id).localeCompare(b.title || b.id);
      });
      if (!q) return sorted;
      return sorted.filter(d => (d.title || '').toLowerCase().includes(q) || d.id.toLowerCase().includes(q));
    },
    get selectedDoc() {
      return this.docs.find(d => d.id === this.selectedDocId) || null;
    },
    get modelsForSelectedDoc() {
      if (!this.selectedDocId) return [];
      return this.models.filter(m => m.documentId === this.selectedDocId);
    },
    get activeModel() {
      return this.modelsForSelectedDoc.find(m => m.name === this.activeModelName) || null;
    },
    // Fields shown in the new-record form: everything except `id` (auto-
    // generated when blank, and typing it by hand is rarely useful).
    get newRecordEditableFields() {
      if (!this.activeModel) return [];
      return this.activeModel.fields.filter(f => f.kind !== 'id');
    },
    get filteredRecords() {
      let list = this.records;
      const q = this.recordFilter.toLowerCase().trim();
      if (q) {
        list = list.filter(r => Object.values(r).some(v => String(v).toLowerCase().includes(q)));
      }
      if (this.recordSort.field) {
        const f = this.recordSort.field;
        const dir = this.recordSort.dir;
        list = list.slice().sort((a, b) => {
          const av = a[f];
          const bv = b[f];
          if (av === bv) return 0;
          return (av > bv ? 1 : -1) * dir;
        });
      }
      return list;
    },

    // ---- selection ----
    // Selecting a doc auto-opens it so the host has time to rebind its
    // InspectableModels against the now-active doc before we render the
    // Records tab. `doc/open` awaits the full sync server-side, so we
    // just wait for its response and then refetch snapshot + models.
    async selectDoc(id) {
      if (this.selectedDocId === id) return;
      this.selectedDocId = id;
      this.activeModelName = '';
      this.records = [];
      const doc = this.docs.find(d => d.id === id);
      if (doc && !doc.isOpen) {
        this.openingDocId = id;
        try {
          await this.doAction('doc/open', { documentId: id });
          await this.fetchSnapshot();
        } finally {
          this.openingDocId = null;
        }
      }
      await this.fetchModels();
    },
    toggleSort(field) {
      if (this.recordSort.field === field) {
        this.recordSort.dir = -this.recordSort.dir;
      } else {
        this.recordSort = { field, dir: 1 };
      }
    },

    // ---- records load ----
    async loadRecords() {
      await this.fetchModels();
      if (!this.activeModel) { this.records = []; return; }
      const url = '/api/models/' + encodeURIComponent(this.activeModel.name)
                + '?documentId=' + encodeURIComponent(this.activeModel.documentId);
      try {
        const r = await fetch(url, { cache: 'no-store' });
        this.records = await r.json();
      } catch { this.records = []; }
    },

    // ---- doc actions ----
    async createDoc() {
      const title = prompt('Document title?', 'Untitled');
      if (title === null) return;
      const res = await this.doAction('doc/create', { title });
      if (res.ok) { this.fetchSnapshot(); this.selectedDocId = res.documentId; }
    },
    async renameDoc() {
      if (!this.selectedDoc) return;
      const title = prompt('New title?', this.selectedDoc.title || '');
      if (title === null) return;
      await this.doAction('doc/rename', { documentId: this.selectedDoc.id, title });
      this.fetchSnapshot();
    },
    async deleteDoc() {
      if (!this.selectedDoc) return;
      if (!confirm('Delete "' + (this.selectedDoc.title || this.selectedDoc.id) + '"? This cannot be undone.')) return;
      await this.doAction('doc/delete', { documentId: this.selectedDoc.id });
      this.selectedDocId = null;
      this.fetchSnapshot();
    },
    async closeDoc() {
      if (!this.selectedDoc) return;
      await this.doAction('doc/close', { documentId: this.selectedDoc.id });
      this.activeModelName = '';
      this.records = [];
      await this.fetchSnapshot();
      await this.fetchModels();
    },
    async shareDoc() {
      if (!this.selectedDoc) return;
      const email = prompt('Collaborator email?');
      if (!email) return;
      const permission = prompt('Permission? (read-write, reader, admin)', 'read-write');
      if (!permission) return;
      await this.doAction('doc/share', { documentId: this.selectedDoc.id, email, permission });
    },

    // ---- record actions ----
    async deleteRecord(id) {
      if (!this.activeModel || !id) return;
      if (!confirm('Delete record ' + id + '?')) return;
      const res = await this.doAction('record/delete', {
        model: this.activeModel.name,
        documentId: this.activeModel.documentId,
        id,
      });
      if (res.ok) this.loadRecords();
    },
    toggleNewRecordForm() {
      if (this.showNewRecordForm) {
        this.showNewRecordForm = false;
        return;
      }
      // Seed per-kind defaults so bindings are well-typed: booleans
      // start `false`, everything else empty string.
      this.newRecord = {};
      this.newRecordError = '';
      for (const f of this.newRecordEditableFields) {
        this.newRecord[f.name] = f.kind === 'boolean' ? false : '';
      }
      this.showNewRecordForm = true;
    },
    async submitNewRecord() {
      if (!this.activeModel) return;
      this.newRecordError = '';
      const values = {};
      for (const f of this.newRecordEditableFields) {
        const raw = this.newRecord[f.name];
        // Empty-ish values: skip (lets server defaults / auto-assign kick
        // in, and keeps `required` fields falling through to the
        // server's own validation so its error message wins).
        const isEmpty = raw === undefined || raw === null || raw === ''
                        || (Array.isArray(raw) && raw.length === 0);
        if (isEmpty && f.kind !== 'boolean') {
          if (!f.optional) {
            this.newRecordError = f.name + ' is required';
            return;
          }
          continue;
        }
        if (f.kind === 'stringset' && typeof raw === 'string') {
          values[f.name] = raw.split(',').map(s => s.trim()).filter(Boolean);
        } else if (f.kind === 'json' && typeof raw === 'string') {
          try {
            values[f.name] = JSON.parse(raw);
          } catch (e) {
            this.newRecordError = f.name + ': invalid JSON (' + e.message + ')';
            return;
          }
        } else {
          values[f.name] = raw;
        }
      }
      this.newRecordSubmitting = true;
      try {
        const res = await this.doAction('record/create', {
          model: this.activeModel.name,
          documentId: this.activeModel.documentId,
          values,
        });
        if (res.ok) {
          this.showNewRecordForm = false;
          this.newRecord = {};
          await this.loadRecords();
        } else if (res.error) {
          this.newRecordError = res.error;
        }
      } finally {
        this.newRecordSubmitting = false;
      }
    },
  };
}
