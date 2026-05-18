// ==== Collections tab ====
// Two-column CRUD: left = collection list + new-collection form,
// right = selected-collection detail (rename/delete, documents in
// it, access control). Access (permissions/members) rendered as
// raw JSON for v1; grant/add are prompt-based.

function collectionsTab() {
  return {
    collections: [], collectionsError: '',
    selectedCollectionId: null,
    collectionFilter: '',
    showNewCollectionForm: false,
    newCollection: { name: '' },
    newCollectionError: '',
    newCollectionSubmitting: false,
    collectionDocs: [], collectionDocsLoading: false,
    collectionAccess: null, collectionAccessError: '',
    collectionAccessLoading: false,
    // Inline "add document to collection" picker state. `docs` comes from
    // the shared snapshot stream in core.js, so no extra fetch needed —
    // we just filter it against `collectionDocs` to hide docs already in.
    showAddDocPicker: false,
    addDocPickerFilter: '',
    // Doc ids whose "add to collection" request is currently in flight.
    // The picker hides these rows the moment they're clicked so a
    // double-click can't fire the same POST twice and 409 on "already
    // in collection". Alpine doesn't make Set instances reactive, so
    // we use a plain object as an id → true map.
    addingDocIds: {},

    // ---- derived ----
    get filteredCollections() {
      const q = this.collectionFilter.toLowerCase().trim();
      if (!q) return this.collections;
      return this.collections.filter(c => {
        const name = String(c.name || c.title || '').toLowerCase();
        const id   = String(c.collectionId || c.id || '').toLowerCase();
        return name.includes(q) || id.includes(q);
      });
    },
    get selectedCollection() {
      if (!this.selectedCollectionId) return null;
      return this.collections.find(c => (c.collectionId || c.id) === this.selectedCollectionId) || null;
    },
    // Docs available to add — the full snapshot list, minus anything
    // already in `collectionDocs`, minus anything with an add currently
    // in flight (so a double-click can't POST twice), optionally
    // text-filtered.
    get addablePickerDocs() {
      const alreadyIn = new Set(this.collectionDocs.map(d => d.documentId || d.id));
      const q = this.addDocPickerFilter.toLowerCase().trim();
      const sorted = this.docs.slice().sort((a, b) => {
        if (a.isOpen !== b.isOpen) return a.isOpen ? -1 : 1;
        return (a.title || a.id).localeCompare(b.title || b.id);
      });
      return sorted.filter(d => {
        if (alreadyIn.has(d.id)) return false;
        if (this.addingDocIds[d.id]) return false;
        if (!q) return true;
        return (d.title || '').toLowerCase().includes(q) || d.id.toLowerCase().includes(q);
      });
    },
    // Resolve a display title for a document in the `collectionDocs`
    // list. The server's listDocuments response only carries ids + some
    // membership metadata — titles aren't populated. Cross-reference
    // against `docs` (the snapshot-fed full list) to get the real title.
    // Falls back to anything the membership record happens to carry,
    // then "(untitled)".
    docTitleForId(id) {
      if (!id) return '(untitled)';
      const d = this.docs.find(x => x.id === id);
      return d?.title || '(untitled)';
    },

    // ---- list + detail loaders ----
    async loadCollections() {
      try {
        const r = await fetch('/api/collections', { cache: 'no-store' });
        const p = await r.json();
        this.collections = p.items || [];
        this.collectionsError = p.error || '';
      } catch (e) { this.collections = []; this.collectionsError = String(e); }
    },
    async loadCollectionDocs() {
      if (!this.selectedCollectionId) { this.collectionDocs = []; return; }
      this.collectionDocsLoading = true;
      try {
        const r = await fetch('/api/collections/' + encodeURIComponent(this.selectedCollectionId) + '/documents', { cache: 'no-store' });
        const p = await r.json();
        this.collectionDocs = p.items || [];
      } catch {
        this.collectionDocs = [];
      } finally {
        this.collectionDocsLoading = false;
      }
    },
    async loadCollectionAccess() {
      if (!this.selectedCollectionId) { this.collectionAccess = null; this.collectionAccessError = ''; return; }
      this.collectionAccessLoading = true;
      try {
        const r = await fetch('/api/collections/' + encodeURIComponent(this.selectedCollectionId) + '/access', { cache: 'no-store' });
        const p = await r.json();
        this.collectionAccess = p.access !== undefined ? p.access : p;
        this.collectionAccessError = p.error || '';
      } catch (e) {
        this.collectionAccess = null;
        this.collectionAccessError = String(e);
      } finally {
        this.collectionAccessLoading = false;
      }
    },

    // ---- CRUD ----
    selectCollection(id) {
      if (this.selectedCollectionId === id) return;
      this.selectedCollectionId = id;
      this.collectionDocs = [];
      this.collectionAccess = null;
      this.collectionAccessError = '';
      this.showAddDocPicker = false;
      this.addDocPickerFilter = '';
      this.addingDocIds = {};
      this.loadCollectionDocs();
      this.loadCollectionAccess();
    },
    toggleNewCollectionForm() {
      if (this.showNewCollectionForm) {
        this.showNewCollectionForm = false;
        return;
      }
      this.newCollection = { name: '' };
      this.newCollectionError = '';
      this.showNewCollectionForm = true;
    },
    async submitNewCollection() {
      if (!this.newCollection.name || !this.newCollection.name.trim()) {
        this.newCollectionError = 'name is required';
        return;
      }
      this.newCollectionSubmitting = true;
      try {
        const res = await this.doAction('col/create', { name: this.newCollection.name.trim() });
        if (res.ok) {
          this.showNewCollectionForm = false;
          this.newCollection = { name: '' };
          await this.loadCollections();
          if (res.collectionId) this.selectedCollectionId = res.collectionId;
        } else if (res.error) {
          this.newCollectionError = res.error;
        }
      } finally {
        this.newCollectionSubmitting = false;
      }
    },
    async renameCollection() {
      if (!this.selectedCollection) return;
      const current = this.selectedCollection.name || this.selectedCollection.title || '';
      const name = prompt('New name?', current);
      if (name === null || name === current) return;
      const id = this.selectedCollection.collectionId || this.selectedCollection.id;
      const res = await this.doAction('col/rename', { collectionId: id, name });
      if (res.ok) await this.loadCollections();
    },
    async deleteCollection() {
      if (!this.selectedCollection) return;
      const name = this.selectedCollection.name || this.selectedCollection.title
                || this.selectedCollection.collectionId || this.selectedCollection.id;
      if (!confirm('Delete "' + name + '"? This cannot be undone.')) return;
      const id = this.selectedCollection.collectionId || this.selectedCollection.id;
      const res = await this.doAction('col/delete', { collectionId: id });
      if (res.ok) {
        this.selectedCollectionId = null;
        await this.loadCollections();
      }
    },
    toggleAddDocPicker() {
      if (this.showAddDocPicker) { this.showAddDocPicker = false; return; }
      this.addDocPickerFilter = '';
      this.showAddDocPicker = true;
    },
    async addDocToCollectionById(documentId) {
      if (!this.selectedCollection || !documentId) return;
      // Already in flight — silently ignore. Protects against the
      // click-through window between "click row" and "row disappears".
      if (this.addingDocIds[documentId]) return;
      const id = this.selectedCollection.collectionId || this.selectedCollection.id;
      this.addingDocIds[documentId] = true;
      try {
        const res = await this.doAction('col/addDoc', { collectionId: id, documentId });
        if (res.ok) {
          // Keep the picker open — `addingDocIds` + the refreshed
          // `collectionDocs` both keep the just-added doc out of the list.
          await this.loadCollectionDocs();
        }
      } finally {
        delete this.addingDocIds[documentId];
      }
    },
    async removeDocFromCollection(documentId) {
      if (!this.selectedCollection || !documentId) return;
      if (!confirm('Remove document ' + documentId.slice(0, 12) + '… from this collection?')) return;
      const id = this.selectedCollection.collectionId || this.selectedCollection.id;
      const res = await this.doAction('col/removeDoc', { collectionId: id, documentId });
      if (res.ok) await this.loadCollectionDocs();
    },
    async grantCollectionPermission() {
      if (!this.selectedCollection) return;
      const groupType = prompt('Group type (e.g. users, role)?');
      if (!groupType) return;
      const groupId = prompt('Group id?');
      if (!groupId) return;
      const permission = prompt('Permission? (read-write, reader, admin)', 'read-write');
      if (!permission) return;
      const id = this.selectedCollection.collectionId || this.selectedCollection.id;
      const res = await this.doAction('col/grant', { collectionId: id, groupType, groupId, permission });
      if (res.ok) await this.loadCollectionAccess();
    },
    async addCollectionMember() {
      if (!this.selectedCollection) return;
      const userId = prompt('userId?');
      if (!userId) return;
      const permission = prompt('Permission? (read-write, reader, admin)', 'read-write');
      if (!permission) return;
      const id = this.selectedCollection.collectionId || this.selectedCollection.id;
      const res = await this.doAction('col/addMember', { collectionId: id, userId, permission });
      if (res.ok) await this.loadCollectionAccess();
    },
  };
}
