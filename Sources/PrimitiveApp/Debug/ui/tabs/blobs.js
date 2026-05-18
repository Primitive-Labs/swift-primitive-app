// ==== Blobs tab ====
// Doc-scoped (js-bao-wss has no standalone blobs). Selection of
// `selectedDocId` drives the list; inline preview for image + text
// MIME types, download/open links for everything else. Upload
// FileReader → base64 → POST /api/action/blob/upload.

function blobsTab() {
  return {
    blobs: [],
    selectedBlobId: null,
    blobUploading: false,
    blobUploadError: '',
    blobTextCache: {},                   // blobId → decoded UTF-8 text
    blobTextLoaded: {},                  // blobId → true once fetched

    // ---- derived ----
    get selectedBlob() {
      if (!this.selectedBlobId) return null;
      return this.blobs.find(b => (b.blobId || b.id) === this.selectedBlobId) || null;
    },

    // ---- loaders + actions ----
    async loadBlobs() {
      if (!this.selectedDocId) { this.blobs = []; return; }
      try {
        const r = await fetch('/api/blobs?documentId=' + encodeURIComponent(this.selectedDocId), { cache: 'no-store' });
        this.blobs = await r.json();
      } catch { this.blobs = []; }
    },
    selectBlob(id) {
      this.selectedBlobId = id;
    },
    async deleteBlob(blobId) {
      if (!confirm('Delete blob ' + blobId + '?')) return;
      const res = await this.doAction('blob/delete', { documentId: this.selectedDocId, blobId });
      if (res.ok) {
        if (this.selectedBlobId === blobId) this.selectedBlobId = null;
        this.loadBlobs();
      }
    },
    async uploadBlob(event) {
      const file = event.target.files && event.target.files[0];
      event.target.value = '';                       // reset input so re-picking same file fires change
      if (!file || !this.selectedDocId) return;
      this.blobUploading = true;
      this.blobUploadError = '';
      try {
        const buf = await file.arrayBuffer();
        // Base64-encode in chunks so very large uploads don't blow the
        // stack that btoa(String.fromCharCode(...bytes)) would push onto.
        const bytes = new Uint8Array(buf);
        let binary = '';
        const chunkSize = 0x8000;
        for (let i = 0; i < bytes.length; i += chunkSize) {
          binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
        }
        const base64 = btoa(binary);
        const res = await this.doAction('blob/upload', {
          documentId: this.selectedDocId,
          filename: file.name,
          contentType: file.type || 'application/octet-stream',
          data: base64,
        });
        if (res.ok) {
          await this.loadBlobs();
          if (res.blobId) this.selectedBlobId = res.blobId;
        } else if (res.error) {
          this.blobUploadError = res.error;
        }
      } catch (e) {
        this.blobUploadError = String(e);
      } finally {
        this.blobUploading = false;
      }
    },

    // ---- preview helpers ----
    isImageContentType(t) {
      return typeof t === 'string' && t.startsWith('image/');
    },
    isTextContentType(t) {
      if (typeof t !== 'string') return false;
      if (t.startsWith('text/')) return true;
      // Common text-ish MIME types that aren't under text/.
      return ['application/json', 'application/javascript', 'application/xml',
              'application/x-yaml', 'application/toml'].some(m => t.startsWith(m));
    },
    blobContentUrl(blob, asDownload) {
      if (!blob || !this.selectedDocId) return '';
      const qs = 'documentId=' + encodeURIComponent(this.selectedDocId)
               + '&blobId=' + encodeURIComponent(blob.blobId || blob.id);
      return '/api/blob/content?' + qs + (asDownload ? '&download=1' : '');
    },
    async loadBlobText(blob) {
      if (!blob) return;
      const id = blob.blobId || blob.id;
      try {
        const r = await fetch(this.blobContentUrl(blob, false), { cache: 'no-store' });
        const text = await r.text();
        this.blobTextCache[id] = text;
        this.blobTextLoaded[id] = true;
      } catch (e) {
        this.blobTextCache[id] = 'failed to load: ' + String(e);
        this.blobTextLoaded[id] = true;
      }
    },
  };
}
