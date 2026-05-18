// ==== Logs tab ====
// Inspector-internal log tail from `InspectorLog.shared` via
// /api/logs. Polled lightly while the tab is active (see core.js
// setInterval on activeTab === 'logs'). `doAction` also calls
// `loadLogs` on failure so the next look has richer context.

function logsTab() {
  return {
    logs: [], logsAutoRefresh: true, logsLevelFilter: '', logsFilter: '',

    // ---- derived ----
    get filteredLogs() {
      let list = this.logs;
      if (this.logsLevelFilter) list = list.filter(l => l.level === this.logsLevelFilter);
      const q = this.logsFilter.toLowerCase().trim();
      if (q) list = list.filter(l => (l.message || '').toLowerCase().includes(q));
      return list;
    },

    // ---- loader ----
    async loadLogs() {
      try {
        const r = await fetch('/api/logs', { cache: 'no-store' });
        const p = await r.json();
        this.logs = p.lines || [];
      } catch { /* ignore */ }
    },
  };
}
