// ==== Tests tab ====
// Runs `InspectorTest`s the host registers via `InspectorTestHost`.
// Tests run sequentially via `/api/action/test/run`; output is a
// concatenated text stream the UI renders in the right panel.

function testsTab() {
  return {
    tests: [],                           // [{ id, group, name }]
    testSelection: {},                   // { [id]: true } — user's run picks
    testResults: {},                     // { [id]: { passed, durationMs, output, error } }
    testRunning: null,                   // currently executing test id; null when idle
    testQueue: [],                       // queue of test ids to run next
    testFilter: '',
    testOutput: '',                      // concatenated output of the current/last run

    // ---- derived ----
    get groupedTests() {
      const groups = {};
      const q = this.testFilter.toLowerCase().trim();
      for (const t of this.tests) {
        if (q && !t.name.toLowerCase().includes(q) && !t.group.toLowerCase().includes(q)) continue;
        if (!groups[t.group]) groups[t.group] = [];
        groups[t.group].push(t);
      }
      return Object.entries(groups).map(([group, items]) => ({ group, items }));
    },
    get selectedTestCount() { return Object.values(this.testSelection).filter(Boolean).length; },
    get passCount() { return Object.values(this.testResults).filter(r => r.passed).length; },
    get failCount() { return Object.values(this.testResults).filter(r => !r.passed).length; },

    // ---- load + selection ----
    async loadTests() {
      try {
        const r = await fetch('/api/tests', { cache: 'no-store' });
        const p = await r.json();
        this.tests = p.tests || [];
      } catch { this.tests = []; }
    },
    toggleTest(id) { this.testSelection[id] = !this.testSelection[id]; },
    toggleGroup(group, items) {
      const allSelected = items.every(t => this.testSelection[t.id]);
      for (const t of items) this.testSelection[t.id] = !allSelected;
    },
    selectAllTests()  { for (const t of this.tests) this.testSelection[t.id] = true; },
    clearSelection()  { this.testSelection = {}; },
    clearResults()    { this.testResults = {}; this.testOutput = ''; },

    // ---- run ----
    async runSelected() {
      const ids = this.tests.filter(t => this.testSelection[t.id]).map(t => t.id);
      if (!ids.length) return;
      await this.runSequence(ids);
    },
    async runAll() {
      await this.runSequence(this.tests.map(t => t.id));
    },
    async runOne(id) { await this.runSequence([id]); },
    async runSequence(ids) {
      this.testQueue = ids.slice();
      this.testOutput = '';
      for (const id of ids) delete this.testResults[id];
      while (this.testQueue.length) {
        const id = this.testQueue.shift();
        this.testRunning = id;
        this.appendTestOutput('\n─── ' + id + ' ───');
        const res = await this.doAction('test/run', { id });
        if (res && res.ok) {
          this.testResults[id] = { passed: res.passed, durationMs: res.durationMs, output: res.output, error: res.error };
          if (res.output) this.appendTestOutput(res.output);
          if (!res.passed) this.appendTestOutput('FAIL: ' + (res.error || '(no message)'));
          this.appendTestOutput((res.passed ? 'PASS' : 'FAIL') + ' · ' + res.durationMs + 'ms');
        } else {
          this.testResults[id] = { passed: false, durationMs: 0, output: '', error: (res && res.error) || 'run failed' };
          this.appendTestOutput('FAIL: ' + ((res && res.error) || 'run failed'));
        }
      }
      this.testRunning = null;
    },
    appendTestOutput(line) {
      this.testOutput += (this.testOutput ? '\n' : '') + line;
      this.$nextTick(() => { const el = this.$refs.testOut; if (el) el.scrollTop = el.scrollHeight; });
    },

    // ---- row rendering ----
    testStatusIcon(id) {
      if (this.testRunning === id) return '◐';
      if (this.testQueue.includes(id)) return '·';
      const r = this.testResults[id];
      if (!r) return '○';
      return r.passed ? '✓' : '✗';
    },
    testStatusColor(id) {
      if (this.testRunning === id) return 'var(--yellow)';
      const r = this.testResults[id];
      if (!r) return 'var(--muted)';
      return r.passed ? 'var(--green)' : 'var(--red)';
    },
    copyTestOutput() {
      if (navigator.clipboard) navigator.clipboard.writeText(this.testOutput);
    },
    copyFailedOutput() {
      const failed = Object.entries(this.testResults).filter(([, r]) => !r.passed);
      const text = failed.map(([id, r]) => '─── ' + id + ' ───\n' + (r.output || '') + '\nFAIL: ' + (r.error || '')).join('\n\n');
      if (navigator.clipboard) navigator.clipboard.writeText(text);
    },
  };
}
