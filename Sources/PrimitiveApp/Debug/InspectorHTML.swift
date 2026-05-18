#if DEBUG
import Foundation

/// Assembles the debug inspector's single-page UI at first access from
/// per-tab HTML + JS fragments bundled as SPM resources.
///
/// The HTTP contract the browser sees stays the same: `GET /` returns
/// one self-contained HTML document with inline `<style>` and
/// `<script>` blocks. The split is purely a development-ergonomics win
/// — each tab's HTML and JS live together in a per-tab file and the
/// file tree mirrors the UI's tab list.
///
/// Layout on disk:
///
/// ```
/// Debug/
///   InspectorHTML.swift          (this file)
///   ui/
///     shell.html                 outer HTML (head, header, tab nav, placeholders)
///     core.css                   shared styles
///     core.js                    factory base: shared state + lifecycle + helpers
///     tabs/
///       overview.html            per-tab <section x-show="activeTab === 'X'">
///       overview.js              per-tab state/getters/methods fragment
///       documents.{html,js}
///       tests.{html,js}
///       databases.{html,js}
///       collections.{html,js}
///       blobs.{html,js}
///       performance.{html,js}
///       sqlite.{html,js}
///       events.{html,js}
///       logs.{html,js}
/// ```
///
/// Assembly:
///   - CSS: `core.css` inlined into `shell.html`'s `/*__INSPECTOR_CSS_PLACEHOLDER__*/`
///   - HTML tabs: every `tabs/{name}.html` concatenated in `tabOrder` into
///     `shell.html`'s `<!--__INSPECTOR_TABS_HTML__-->`
///   - JS tabs: every `tabs/{name}.js` concatenated in `tabOrder` into
///     `core.js`'s `/*__INSPECTOR_TABS_JS__*/`, which itself is inlined
///     into `shell.html`'s `/*__INSPECTOR_JS_PLACEHOLDER__*/`
///
/// Each tab JS file is a raw object-literal fragment (trailing comma on
/// every property) designed to be spliced into the `inspector()`
/// factory's return value — they're not standalone modules.
///
/// Missing-resource / parse failure is a precondition crash: the
/// inspector is DEBUG-only and a missing resource means the dev's build
/// is broken.
enum InspectorHTML {

    /// Tab order — drives both the HTML section order in `<main>` and
    /// the JS fragment merge order. The JS factory uses flat keys (no
    /// collisions in practice), so the merge order only matters for
    /// determinism. HTML order governs z-index and is visually
    /// meaningful for `x-show` toggles.
    ///
    /// Keep this aligned with the `tabs:` array declared in `core.js`.
    private static let tabOrder: [String] = [
        "overview",
        "documents",
        "tests",
        "databases",
        "collections",
        "blobs",
        "performance",
        "sqlite",
        "memdb",
        "events",
        "logs",
    ]

    /// The fully-assembled page served at `GET /`. Built once on first
    /// access; cached for process lifetime.
    ///
    /// Each tab JS file is a standalone function definition like
    /// `function overviewTab() { return { ... }; }`, so the browser
    /// parses each concatenated file as valid JS. `core.js`'s
    /// `inspector()` factory merges those fragments at runtime via
    /// `Object.defineProperties(base, Object.getOwnPropertyDescriptors(fn()))`
    /// so getter accessors survive the merge (plain `Object.assign`
    /// would snapshot the getter's return to a data property).
    static let page: String = {
        do {
            let shell   = try loadResource(subpath: "ui", name: "shell", ext: "html")
            let css     = try loadResource(subpath: "ui", name: "core",  ext: "css")
            let coreJS  = try loadResource(subpath: "ui", name: "core",  ext: "js")

            let tabsHTML = try tabOrder.map { name in
                try loadResource(subpath: "ui/tabs", name: name, ext: "html")
            }.joined(separator: "\n")

            let tabJSFiles = try tabOrder.map { name in
                try loadResource(subpath: "ui/tabs", name: name, ext: "js")
            }.joined(separator: "\n")

            // Core first (defines `inspector()`), then each tab's factory.
            // The factory names are already known to core.js via
            // `__INSPECTOR_TAB_FACTORIES__`; it probes for them at call
            // time, so order between core and tabs only matters for
            // parse (core must be first so `inspector` is declared
            // before Alpine evaluates `x-data`).
            let js = coreJS + "\n" + tabJSFiles

            return shell
                .replacingOccurrences(of: "/*__INSPECTOR_CSS_PLACEHOLDER__*/", with: css)
                .replacingOccurrences(of: "<!--__INSPECTOR_TABS_HTML__-->", with: tabsHTML)
                .replacingOccurrences(of: "/*__INSPECTOR_JS_PLACEHOLDER__*/", with: js)
        } catch {
            preconditionFailure("DebugInspector: failed to assemble page — \(error)")
        }
    }()

    // MARK: - Resource loading

    /// Locate a bundled resource. SPM flattens the directory structure
    /// when building the resource bundle — `ui/tabs/overview.html` ends
    /// up at `overview.html` inside `PrimitiveApp_PrimitiveApp.bundle`.
    /// We try both shapes so local tooling that preserves the tree
    /// (e.g. running the HTML directly in a browser from disk) also
    /// works.
    private static func loadResource(subpath: String, name: String, ext: String) throws -> String {
        let tryLoad: (Bundle) -> String? = { bundle in
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subpath) {
                return try? String(contentsOf: url, encoding: .utf8)
            }
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return try? String(contentsOf: url, encoding: .utf8)
            }
            return nil
        }
        #if SWIFT_PACKAGE
        if let text = tryLoad(Bundle.module) { return text }
        #endif
        if let text = tryLoad(Bundle.main) { return text }
        throw InspectorResourceError.missing(name: "\(subpath)/\(name).\(ext)")
    }

    private enum InspectorResourceError: Error, CustomStringConvertible {
        case missing(name: String)
        var description: String {
            switch self {
            case let .missing(name):
                return "\(name) not found in Bundle.module / Bundle.main — check Package.swift resources + Xcode target membership"
            }
        }
    }
}
#endif
