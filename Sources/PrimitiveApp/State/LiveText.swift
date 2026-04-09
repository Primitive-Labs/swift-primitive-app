import Foundation
import SwiftUI
import JsBaoClient
import YSwift

// MARK: - StringEditDelta

/// A single replace-range edit computed by diffing two snapshots of a string.
///
/// All offsets and lengths are expressed in **UTF-16 code units**, which is what
/// YText (and Yjs) use natively for indexing. Use ``init(from:to:)`` to compute the
/// minimal common-prefix/common-suffix delta between two strings.
public struct StringEditDelta: Equatable, Sendable {
    /// Start position in the OLD string, in UTF-16 code units.
    public let start: Int
    /// Number of UTF-16 code units to remove from the OLD string starting at `start`.
    public let removeCount: Int
    /// Replacement text to insert at `start` after the removal.
    public let insert: String

    public init(start: Int, removeCount: Int, insert: String) {
        self.start = start
        self.removeCount = removeCount
        self.insert = insert
    }

    /// True when the delta represents no change.
    public var isNoOp: Bool {
        removeCount == 0 && insert.isEmpty
    }

    /// Computes the minimal common-prefix / common-suffix delta from `old` to `new`.
    ///
    /// Works at UTF-16 code unit granularity to match YText's index space. Handles
    /// 99% of editor-style edits cleanly: type-a-char, backspace, paste, select-and-replace.
    /// For pathological cases (large reorderings), this returns one big replace-range.
    ///
    /// Surrogate-pair safety: if the prefix/suffix scan would split a UTF-16 surrogate
    /// pair (e.g. emoji A → emoji B with the same high surrogate), the boundary is
    /// nudged outward so the entire pair lands inside the replacement section. This
    /// guarantees the resulting `insert` string is always valid UTF-16.
    public init(from old: String, to new: String) {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)

        let oldLen = oldUnits.count
        let newLen = newUnits.count

        // Find common prefix length.
        var prefix = 0
        let maxPrefix = min(oldLen, newLen)
        while prefix < maxPrefix && oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }

        // Find common suffix length, bounded so it doesn't overlap the prefix.
        var suffix = 0
        let maxSuffix = min(oldLen, newLen) - prefix
        while suffix < maxSuffix && oldUnits[oldLen - 1 - suffix] == newUnits[newLen - 1 - suffix] {
            suffix += 1
        }

        // Surrogate-pair correction. If the kept prefix ends in a high surrogate
        // (0xD800..0xDBFF), the very next unit was its low-surrogate partner; if
        // that partner is in the replaced section we'd leave the high orphaned.
        // Back off the prefix so the high surrogate is replaced too.
        if prefix > 0 {
            let lastKept = oldUnits[prefix - 1]
            if (0xD800...0xDBFF).contains(lastKept) {
                prefix -= 1
            }
        }
        // Symmetric: if the kept suffix starts with a low surrogate (0xDC00..0xDFFF),
        // its high-surrogate partner is in the replaced section. Back off the suffix.
        if suffix > 0 {
            let firstKept = oldUnits[oldLen - suffix]
            if (0xDC00...0xDFFF).contains(firstKept) {
                suffix -= 1
            }
        }

        let removeCount = oldLen - prefix - suffix
        let insertUnits = Array(newUnits[prefix..<(newLen - suffix)])
        let insertString = String(decoding: insertUnits, as: UTF16.self)

        self.start = prefix
        self.removeCount = removeCount
        self.insert = insertString
    }
}

// MARK: - LiveText

/// Reactive wrapper around a Y.Text shared type for real-time collaborative editing.
///
/// Drop-in for SwiftUI text editors. Bind it to a document/text-name once,
/// then pass `binding` to a `TextEditor` or `TextField`. User edits are diffed
/// against the previous value at UTF-16 granularity and applied as Y.Text
/// insert / removeRange operations. Remote changes flow back into ``text``
/// reactively, triggering a SwiftUI re-render.
///
/// Usage:
/// ```swift
/// @StateObject var liveText = LiveText()
///
/// var body: some View {
///     TextEditor(text: liveText.binding)
///         .task {
///             liveText.bind(client: client, documentId: docId, name: "myDoc")
///         }
///         .onDisappear { liveText.unbind() }
/// }
/// ```
///
/// **Important:** ``bind(client:documentId:name:)`` resolves the YText handle
/// outside of any open transaction (the safe pattern). Callers do not need to
/// touch transactions, maps, or YText directly — and they cannot accidentally
/// trip the get-inside-transact deadlock.
@MainActor
public final class LiveText: ObservableObject {

    // MARK: - Published State

    /// The current text. Updates automatically on remote changes. To write,
    /// use ``binding`` from a SwiftUI editor or call ``setText(_:)``.
    @Published public private(set) var text: String = ""

    /// True once `bind` has resolved a YText handle and read the initial state.
    @Published public private(set) var isReady: Bool = false

    /// Timestamp of the most recent REMOTE change (i.e. an update that wasn't
    /// caused by a local edit through `binding`/`setText`). `nil` until the
    /// first remote update arrives.
    @Published public private(set) var lastRemoteUpdate: Date?

    // MARK: - Private

    private var ytext: YText?
    private var observerTask: Task<Void, Never>?
    private var documentId: String?
    private var textName: String?

    /// Suppresses the binding-set path when we're internally syncing `text`
    /// from a remote update. Without this, binding-set would diff a remote
    /// arrival against the previous value and re-issue the same edit.
    private var isApplyingRemoteUpdate = false

    public init() {}

    // MARK: - SwiftUI Binding

    /// SwiftUI binding for `TextEditor` / `TextField`. Each user edit is diffed
    /// against the previous value at UTF-16 granularity and applied to the
    /// underlying Y.Text as a single insert/remove pair.
    public var binding: Binding<String> {
        Binding(
            get: { self.text },
            set: { newValue in
                guard !self.isApplyingRemoteUpdate else { return }
                guard newValue != self.text else { return }
                let oldValue = self.text
                self.text = newValue
                self.applyLocalEdit(from: oldValue, to: newValue)
            }
        )
    }

    /// Programmatic write — same effect as setting `binding` from an editor.
    public func setText(_ newValue: String) {
        guard newValue != self.text else { return }
        let oldValue = self.text
        self.text = newValue
        applyLocalEdit(from: oldValue, to: newValue)
    }

    // MARK: - Binding lifecycle

    /// Bind this `LiveText` to a Y.Text shared type within an open document.
    ///
    /// Safe to call from `.task` or `.onAppear`. Idempotent — calling with the
    /// same (documentId, name) is a no-op. Calling with different values rebinds.
    ///
    /// - Parameters:
    ///   - client: The connected `JsBaoClient`. The document must already be open.
    ///   - documentId: The document containing the shared text.
    ///   - name: The Y.Text name within the document (e.g. `"liveDemoText"`).
    public func bind(client: JsBaoClient?, documentId: String?, name: String) {
        guard let client, let documentId, let doc = client.getDoc(documentId) else {
            unbind()
            return
        }

        // Idempotent: skip if already bound to the same target.
        if self.documentId == documentId, self.textName == name, ytext != nil {
            return
        }

        unbind()

        // SAFETY: getOrCreateText is called OUTSIDE any transaction. This is
        // the same get-or-insert pattern as getMap and would deadlock if
        // called from inside a transact() closure.
        let resolved = doc.getOrCreateText(named: name)
        self.ytext = resolved
        self.documentId = documentId
        self.textName = name

        // Read initial state, then start observing.
        Task { [weak self] in
            guard let self else { return }
            let initial = await resolved.getStringAsync()
            await MainActor.run {
                // Initial load is not considered a remote change — don't bump
                // lastRemoteUpdate, just seed `text` directly.
                if initial != self.text {
                    self.isApplyingRemoteUpdate = true
                    self.text = initial
                    self.isApplyingRemoteUpdate = false
                }
                self.isReady = true
            }
            self.startObserving(resolved)
        }
    }

    /// Stop observing and clear state.
    public func unbind() {
        observerTask?.cancel()
        observerTask = nil
        ytext = nil
        documentId = nil
        textName = nil
        isReady = false
        // Clear text last so observers see ready=false first.
        if !text.isEmpty {
            isApplyingRemoteUpdate = true
            text = ""
            isApplyingRemoteUpdate = false
        }
    }

    deinit {
        observerTask?.cancel()
    }

    // MARK: - Private: write path

    private func applyLocalEdit(from oldValue: String, to newValue: String) {
        guard let ytext else { return }
        let delta = StringEditDelta(from: oldValue, to: newValue)
        guard !delta.isNoOp else { return }

        // The captured `delta` is value-typed and Sendable; ytext is a class that
        // we keep alive across await points by capturing locally.
        Task {
            if delta.removeCount > 0 {
                await ytext.removeRange(start: UInt32(delta.start), length: UInt32(delta.removeCount))
            }
            if !delta.insert.isEmpty {
                await ytext.insert(delta.insert, at: UInt32(delta.start))
            }
        }
    }

    // MARK: - Private: observe path

    private func startObserving(_ ytext: YText) {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            let stream = ytext.observeAsync()
            for await _ in stream {
                if Task.isCancelled { break }
                let snapshot = await ytext.getStringAsync()
                await MainActor.run { [weak self] in
                    self?.applyRemoteSnapshot(snapshot)
                }
            }
        }
    }

    private func applyRemoteSnapshot(_ snapshot: String) {
        // The YText observer fires for ALL writes, including our own. If the
        // snapshot matches what we already have locally, it was caused by our
        // most recent write — not a remote change. Skip both the @Published
        // bump (no need) and the lastRemoteUpdate timestamp.
        guard snapshot != text else { return }

        isApplyingRemoteUpdate = true
        text = snapshot
        isApplyingRemoteUpdate = false
        lastRemoteUpdate = Date()
    }
}
