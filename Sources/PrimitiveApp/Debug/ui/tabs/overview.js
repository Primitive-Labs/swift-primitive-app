// ==== Overview tab ====
// Pure dashboard — no state of its own. Reads `conn` / `user` / `docs`
// (owned by core.js via /api/snapshot) and tails the live `events`
// stream (owned by core.js via SSE). Factory returns an empty object
// so the merge loop is a no-op; kept as a placeholder for future
// Overview-only controls.

function overviewTab() {
  return {};
}
