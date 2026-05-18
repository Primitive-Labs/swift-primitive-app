// ==== Events tab ====
// The live SSE stream is captured + appended in core.js (`pushEvent`
// from `connectEvents`). This tab just adds filter state + derived
// views for rendering. Pause / auto-scroll / replay-on-mount all
// read `events`, `eventsPaused`, `eventAutoScroll` from core.

function eventsTab() {
  return {
    eventFilter: '',
    eventTypeFilter: '',

    // ---- derived ----
    get eventTypes() {
      return Array.from(new Set(this.events.map(e => e.type))).sort();
    },
    get filteredEvents() {
      let list = this.events;
      if (this.eventTypeFilter) list = list.filter(e => e.type === this.eventTypeFilter);
      const q = this.eventFilter.toLowerCase().trim();
      if (q) list = list.filter(e => JSON.stringify(e).toLowerCase().includes(q));
      return list;
    },
  };
}
