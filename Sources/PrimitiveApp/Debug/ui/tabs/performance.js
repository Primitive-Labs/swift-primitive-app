// ==== Performance tab ====
// Live data-flow timeline derived directly from the SSE event stream
// that core.js continuously consumes. No polling, no separate fetch:
// every time `pushEvent` fires, `perfTimeline` / `perfSummary` /
// `perfDocIds` recompute and Alpine re-renders.
//
// The server emits four perf-relevant events; we flatten each into a
// phase row with the same shape the old (polled) `/api/perf` endpoint
// used to produce:
//   documentLoaded  → loadedFromSqlite (source=sqlite) or loadedFromServer
//   documentClosed  → closed
//   sync (synced=true) → synced
//   documentSyncStateChanged (synced) → syncStateChanged
//
// SSE's on-connect replay (last 500 events) fills in history for free,
// so new tabs don't paint empty.

function performanceTab() {
  return {
    perfDocFilter: '',
    // "Clear" doesn't mutate the shared `events` buffer (the Events tab
    // reads the same array). Instead we record a cutoff timestamp; the
    // timeline + summary only consider events with `ts > cutoff`. Click
    // "clear" again to reset — each click just moves the cutoff forward.
    perfClearedBeforeTs: 0,

    // ---- derivation from SSE events ----

    /// Translate one SSE event into a phase string, or null if the
    /// event isn't perf-relevant. Single source of truth for which
    /// events the timeline + summary + doc-filter dropdown all agree
    /// on.
    perfPhaseFromEvent(e) {
      if (!e || !e.type) return null;
      if (e.type === 'documentLoaded') {
        return e.source === 'sqlite' ? 'loadedFromSqlite' : 'loadedFromServer';
      }
      if (e.type === 'documentClosed') return 'closed';
      if (e.type === 'sync' && e.synced) return 'synced';
      if (e.type === 'documentSyncStateChanged' && e.state === 'synced') return 'syncStateChanged';
      return null;
    },

    /// Subset of `events` the Perf tab considers: perf-relevant + post-
    /// cutoff. Doing the filter once (as a cached getter) keeps the
    /// three downstream getters — docIds, timeline, summary — consistent
    /// and saves a little work vs. each re-scanning the full buffer.
    get perfVisibleEvents() {
      const cutoff = this.perfClearedBeforeTs;
      const out = [];
      for (const e of this.events) {
        if (e.ts <= cutoff) continue;
        if (!this.perfPhaseFromEvent(e)) continue;
        out.push(e);
      }
      return out;
    },

    get perfDocIds() {
      const set = new Set();
      for (const e of this.perfVisibleEvents) {
        if (e.documentId) set.add(e.documentId);
      }
      return Array.from(set);
    },

    get perfTimeline() {
      const rows = [];
      for (const e of this.perfVisibleEvents) {
        if (this.perfDocFilter && e.documentId !== this.perfDocFilter) continue;
        const phase = this.perfPhaseFromEvent(e);
        rows.push({
          ts: e.ts,
          docId: e.documentId,
          phase,
          label: this.perfPhaseLabel(phase),
          icon: this.perfPhaseIcon(phase),
          elapsedMs: e.elapsedMs,
          bytes: e.bytes,
          modelHint: this.perfModelHintForDoc(e.documentId, phase),
        });
      }
      // Newest first — reads naturally from top of screen for a live
      // tail. (The old ascending order was a hangover from the Gantt
      // days where "left-to-right = time".)
      rows.sort((a, b) => b.ts - a.ts);
      return rows;
    },

    get perfSummary() {
      let docsOpened = 0;
      let sqliteCount = 0;
      let sqliteBytes = 0;
      let sqliteMs = 0;
      let serverCount = 0;
      let serverBytes = 0;
      let serverMs = 0;
      let syncStateChanges = 0;
      let eventCount = 0;
      const sawDocIds = new Set();
      for (const e of this.perfVisibleEvents) {
        const phase = this.perfPhaseFromEvent(e);
        eventCount++;
        if (e.documentId && (phase === 'loadedFromSqlite' || phase === 'loadedFromServer')) {
          sawDocIds.add(e.documentId);
        }
        if (phase === 'loadedFromSqlite') {
          sqliteCount++;
          if (e.bytes) sqliteBytes += e.bytes;
          if (e.elapsedMs) sqliteMs += e.elapsedMs;
        }
        if (phase === 'loadedFromServer') {
          serverCount++;
          if (e.bytes) serverBytes += e.bytes;
          if (e.elapsedMs) serverMs += e.elapsedMs;
        }
        if (phase === 'syncStateChanged') syncStateChanges++;
      }
      docsOpened = sawDocIds.size;
      return { eventCount, docsOpened, sqliteCount, sqliteBytes, sqliteMs,
               serverCount, serverBytes, serverMs, syncStateChanges };
    },

    // ---- actions ----

    /// Hide everything currently visible on the perf tab. Doesn't touch
    /// the shared `events` buffer — future events keep streaming in.
    clearPerf() {
      this.perfClearedBeforeTs = Date.now();
    },

    // ---- labels / icons / hints ----
    perfPhaseLabel(p) {
      switch (p) {
        case 'opening':          return 'open document — started';
        case 'loadedFromSqlite': return 'read from offline cache (sqlite)';
        case 'loadedFromServer': return 'downloaded from server';
        case 'synced':           return 'sync complete';
        case 'syncStateChanged': return 'document sync state changed';
        case 'closed':           return 'closed document';
        default:                 return p;
      }
    },
    perfPhaseIcon(p) {
      switch (p) {
        case 'opening':          return '📂';
        case 'loadedFromSqlite': return '💾';
        case 'loadedFromServer': return '🌐';
        case 'synced':           return '✅';
        case 'syncStateChanged': return '📡';
        case 'closed':           return '🚪';
        default:                 return '·';
      }
    },
    perfDocLabel(docId) {
      const d = this.docs.find(x => x.id === docId);
      const shortId = String(docId).slice(0, 12) + '…';
      return d ? ((d.title || '(untitled)') + ' · ' + shortId) : shortId;
    },
    perfModelHintForDoc(docId, phase) {
      // Only annotate the phases where "which models live on this doc"
      // is meaningful. On `synced` the host's models are wired up — good
      // time to hint at what they are. Uses the shared `models` cache
      // (core.js). Falls silent if models haven't loaded yet.
      if (phase !== 'synced') return null;
      if (!this.models || !this.models.length) return null;
      const mine = this.models.filter(m => m.documentId === docId);
      if (!mine.length) return null;
      const plural = mine.length === 1 ? '' : 's';
      return mine.length + ' model' + plural + ' registered: ' + mine.map(m => m.name).join(', ');
    },
  };
}
