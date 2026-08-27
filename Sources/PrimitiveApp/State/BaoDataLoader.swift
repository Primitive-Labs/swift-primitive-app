import Foundation
import SwiftUI
import JsBaoClient

// MARK: - LoaderTrigger

/// Declarative event triggers for `BaoDataLoader.bind(...)`.
///
/// Each case represents a class of `JsBaoClient` event that should cause the
/// loader to schedule a (debounced) reload. The default `subscribeTo` for
/// `bind(...)` is `[.onDocumentEvents]`, mirroring the JS
/// `useJsBaoDataLoader`'s `reloadOnDocumentEvents: true` default.
///
/// Use `.custom` for anything not covered by the named cases — e.g. listening
/// to typed workflow events, or driving a reload from your own publisher.
public enum LoaderTrigger {
    /// Reload on `JsBaoEvent.sync` — fires whenever a document finishes (re)syncing.
    /// Useful for model-backed loaders.
    case onSync

    /// Reload on `JsBaoEvent.documentSyncStateChanged` with `state == "synced"`
    /// whenever a remote write lands in any open document. Pair with `.onSync`
    /// for full model reactivity.
    case onDocumentSyncStateChanged

    /// Reload on `JsBaoEvent.documentLoaded` and `JsBaoEvent.documentClosed`.
    /// Matches the JS loader's `reloadOnDocumentEvents` flag (default on).
    case onDocumentEvents

    /// Reload when the connection status flips to `.connected`. Useful for
    /// REST-backed loaders that need to refresh after reconnect.
    case onConnect

    /// Reload whenever a specific `DynamicModel` records an add, update, or
    /// delete. Fires for both local and remote writes, debounced like the
    /// other triggers.
    ///
    /// For codegen'd models, prefer ``onModel(subscribe:)`` — it binds to the
    /// model's cross-document shared store rather than a single `DynamicModel`
    /// instance.
    case onModelChange(ModelSubscribable)

    /// Reload whenever a codegen'd model's shared store records an add,
    /// update, or delete — across every open document. Pass the generated
    /// `Model.subscribe` static directly:
    ///
    /// ```swift
    /// loader.bind(client: client, subscribeTo: [.onModel(subscribe: TaskRecord.subscribe)]) { _ in
    ///     try TaskRecord.findAll()
    /// }
    /// ```
    ///
    /// The closest analogue to JS-bao's per-model `Model.subscribe`
    /// reactivity — tighter than `.onSync` + `.onDocumentSyncStateChanged`
    /// (no spurious reloads from unrelated models) and matches the JS pattern
    /// of binding views to model events.
    ///
    /// The callback is `@Sendable` (#1992), matching the signature codegen
    /// emits for `Model.subscribe`: it fires on whichever thread committed
    /// the change, so anything it captures must be safe to touch from there.
    case onModel(subscribe: (@escaping @Sendable () -> Void) -> @Sendable () -> Void)

    /// Caller-supplied subscription installer. Receive the connected client and
    /// a `reload` callback; install whatever event subscription you want and
    /// return it (or `nil` if you don't want to install anything). The loader
    /// holds the subscription and cancels it on `unbind` / deinit.
    case custom((JsBaoClient, @escaping () -> Void) -> EventSubscription?)
}

/// Anything the loader can subscribe to for `.onModelChange`. `DynamicModel`
/// conforms via the retroactive extension below — keeps `swift-client` from
/// having to know about the loader. (Codegen'd models use ``LoaderTrigger/onModel(subscribe:)``
/// instead, which takes the generated `Model.subscribe` static.)
public protocol ModelSubscribable: AnyObject {
    /// Register a callback that fires after any add, update, or delete on
    /// the model. Returns an unsubscribe closure.
    ///
    /// The callback is `@Sendable` (#1992): `DynamicModel` fires it on
    /// whichever thread committed the change — a local writer's thread, or
    /// the observer-drain queue.
    @discardableResult
    func subscribe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

// `DynamicModel.subscribe(...)` matches the protocol signature exactly,
// including the `@Sendable` requirement on both closure types (#1992).
extension DynamicModel: ModelSubscribable {}

// MARK: - LoaderPhase

/// View-facing trinary load state. Returned by `BaoDataLoader.phase`.
///
/// The `loader.data ?? []` pattern is a common foot-gun: it collapses
/// "first load hasn't completed yet" and "first load completed, no
/// results" into the same view branch, so empty-state placeholders
/// flash for ~50ms (or longer if a parent view does async setup
/// before binding) on every fresh detail-view appearance.
///
/// `LoaderPhase` distinguishes the two without making callers
/// remember to inspect `initialDataLoaded`:
///
/// ```swift
/// switch loader.phase {
/// case .loading:        ProgressView()
/// case .empty:          EmptyState()
/// case .loaded(let d):  List(d) { row in … }
/// }
/// ```
public enum LoaderPhase<Data> {
    case loading
    case empty
    case loaded(Data)
}

/// Protocol the loader uses to decide whether loaded data is empty
/// (and therefore should surface as `.empty` rather than `.loaded`).
///
/// `[T]` and `String` get conformances out of the box. Custom `Data`
/// types (tuples, structs of aggregated values, etc.) that want to
/// participate in `.empty` should adopt this protocol. Types that
/// don't conform are always treated as non-empty when present —
/// callers will only see `.loading` and `.loaded(data)`.
public protocol LoaderEmptiness {
    var isLoaderEmpty: Bool { get }
}

extension Array: LoaderEmptiness {
    public var isLoaderEmpty: Bool { isEmpty }
}

extension String: LoaderEmptiness {
    public var isLoaderEmpty: Bool { isEmpty }
}

extension Optional: LoaderEmptiness where Wrapped: LoaderEmptiness {
    public var isLoaderEmpty: Bool {
        switch self {
        case .none: return true
        case .some(let w): return w.isLoaderEmpty
        }
    }
}

// MARK: - BaoDataLoader

/// Reactive data-loading helper modeled after the JS `useJsBaoDataLoader`
/// composable. Owns one piece of fetched data and the event subscriptions
/// that should cause it to refresh.
///
/// Generic over `Data` so callers pick the return shape — a single record,
/// `[T]`, a tuple/struct of derived values, anything. The `load` closure is
/// arbitrary, so the same loader works for model records, raw REST
/// resources, or multi-source aggregations.
///
/// Differences from JS:
/// - Drops the second `Q` (queryParams) generic. Filter state lives in the
///   View as `@State`; trigger reloads from `.onChange(of:)`.
/// - `subscribeTo` takes a `[LoaderTrigger]` enum array instead of model
///   classes (the Swift model facade's per-class pub/sub is `Model.subscribe`; the
///   equivalent reactivity is `JsBaoClient.stream(for:)` /
///   `observeOnMainActor(_:handler:)`).
/// - Settable `documentReady` / `isPaused` / `debounceInterval` properties so
///   you can flip them mid-flight without rebinding.
/// - `error` is `@Published` (in addition to the optional `onError` callback).
///
/// Usage:
/// ```swift
/// @StateObject private var loader = BaoDataLoader<[CollectionItem]>()
///
/// var body: some View {
///     List(loader.data ?? []) { /* ... */ }
///         .task {
///             loader.bind(client: appState.client) { client in
///                 let resp = try await client.collections.list(options: PaginationOptions(limit: 50))
///                 return (resp["items"] as? [[String: Any]] ?? []).map(CollectionItem.init)
///             }
///         }
/// }
/// ```
///
/// Cleanup happens automatically: `BaoDataLoader.deinit` cancels event
/// subscriptions and the pending reload Task, and `@StateObject` deinits the
/// loader when the view is destroyed. **Don't** wire `.onDisappear { loader.unbind() }`
/// — inside a `NavigationSplitView` detail slot, SwiftUI routes a stale
/// disappearance event through `_AppearanceActionModifier` on the *new* view
/// instance milliseconds after `.task` runs, which would cancel the
/// just-scheduled reload Task and leave the view permanently empty on
/// re-open. If you genuinely need to release subscriptions before the view
/// is destroyed (e.g. a loader owned by a long-lived view model), call
/// `unbind()` from a non-lifecycle hook.
@MainActor
public final class BaoDataLoader<Data>: ObservableObject {

    // MARK: - Published State

    /// Latest successfully loaded data, or `nil` before the first load completes.
    @Published public private(set) var data: Data?

    /// `true` after the first successful load (resets when `documentReady` becomes `false`).
    /// Distinguishes "still loading" from "loaded but empty" so views can show the
    /// right placeholder.
    @Published public private(set) var initialDataLoaded = false

    /// `true` while a load is currently in flight.
    @Published public private(set) var isLoading = false

    /// Last error from `load` (cleared on the next successful load). Surface this
    /// in your view if you want users to see failures instead of silently empty
    /// lists.
    @Published public private(set) var error: Error?

    /// Anti-flash loading flag. Gate your skeleton/placeholder UI on this
    /// instead of `phase == .loading` (or `isLoading`) when you want to avoid
    /// a skeleton flashing on fast warm reloads. Mirrors the JS
    /// `useJsBaoDataLoader`'s `showSkeleton`:
    ///
    ///  - `true` immediately while the document is *opening* (`documentReady`
    ///    is `false`) — the dominant initial-load wait, where no load runs yet.
    ///  - once `documentReady` is `true` and a load is in flight but the first
    ///    load hasn't completed, `true` only after the load has run longer than
    ///    ``skeletonDelay`` — so a warm reload that resolves from local CRDT
    ///    state in a few milliseconds never flashes a skeleton.
    ///  - `false` once the first load completes (`initialDataLoaded`), and
    ///    stays `false` across reactive reloads of an already-loaded document.
    ///
    /// ```swift
    /// if loader.showSkeleton {
    ///     SkeletonList()
    /// } else {
    ///     switch loader.phase { … }
    /// }
    /// ```
    @Published public private(set) var showSkeleton: Bool = false

    /// View-facing trinary phase. The canonical `List(loader.data ?? [])`
    /// shape collapses "still loading" and "loaded but empty" into the
    /// same render — so views that show an empty-state placeholder
    /// flash that placeholder for the duration of the first load. Prefer
    /// this property:
    ///
    /// ```swift
    /// switch loader.phase {
    /// case .loading:       ProgressView()
    /// case .empty:         EmptyState()
    /// case .loaded(let d): List(d) { … }
    /// }
    /// ```
    ///
    /// The phase is derived from `initialDataLoaded` + `data`; it
    /// always returns `.loading` until the first successful load lands.
    /// `.empty` requires the loaded `Data` to satisfy `LoaderEmptiness`
    /// — `[T]` and `String` get conformances out of the box; custom
    /// `Data` types must adopt `LoaderEmptiness` to participate.
    public var phase: LoaderPhase<Data> {
        guard initialDataLoaded, let data else { return .loading }
        if let empty = data as? LoaderEmptiness, empty.isLoaderEmpty {
            return .empty
        }
        return .loaded(data)
    }

    // MARK: - Configuration

    /// Gate for the loader: while `false`, no loads run and `initialDataLoaded`
    /// resets to `false`. Flip to `true` once your document/state is ready and
    /// the loader will fire an immediate (debounced) load. Mirrors the JS
    /// loader's `documentReady` parameter.
    public var documentReady: Bool = true {
        didSet {
            guard oldValue != documentReady else { return }
            handleDocumentReadyChange()
        }
    }

    /// Pause flag. While `true`, no loads (manual or scheduled) run.
    public var isPaused: Bool = false

    /// Debounce interval for scheduled reloads. Default 50ms.
    public var debounceInterval: TimeInterval = 0.05

    /// Delay before ``showSkeleton`` flips to `true` while a first load is in
    /// flight (with `documentReady == true`). If the load completes before
    /// this delay, the skeleton never shows. Default 100ms. The Swift analogue
    /// of the JS loader's `skeletonDelayMs` option (seconds here, matching
    /// ``debounceInterval``'s units).
    public var skeletonDelay: TimeInterval = 0.1

    // MARK: - Private state

    private weak var client: JsBaoClient?
    private var loadClosure: (@MainActor (JsBaoClient) async throws -> Data)?
    private var onErrorCallback: ((Error) -> Void)?
    private var subscriptions: [EventSubscription] = []
    private var reloadTask: Task<Void, Never>?
    private var loadGeneration: Int = 0

    /// Timer that flips `skeletonDelayElapsed` once `skeletonDelay` passes while
    /// a first load is in flight. `nil` when not armed.
    private var skeletonTimerTask: Task<Void, Never>?

    /// `true` once the skeleton-delay timer has fired during an in-flight first
    /// load. Feeds `showSkeleton` while `documentReady` and not yet loaded.
    private var skeletonDelayElapsed: Bool = false

    /// Subscriptions only fire reloads after the first successful load. Prevents
    /// races where a `.sync` event arrives during the initial load and we
    /// double-fetch.
    private var subscriptionsEnabled: Bool = false

    public init() {}

    deinit {
        // We can't touch MainActor state from deinit, but cancelling
        // EventSubscriptions and Tasks is safe from any thread.
        for sub in subscriptions { sub.cancel() }
        reloadTask?.cancel()
        skeletonTimerTask?.cancel()
    }

    // MARK: - Bind / unbind

    /// Wire the loader up to a client and a load closure, install any event
    /// subscriptions in `subscribeTo`, and (if `documentReady`) trigger an
    /// initial load.
    ///
    /// Safe to call from `.task` / `.onAppear`. Calling `bind` again replaces
    /// the previous binding (subscriptions are cancelled, then reinstalled).
    ///
    /// - Parameters:
    ///   - client: The connected `JsBaoClient`. Pass `nil` to no-op.
    ///   - subscribeTo: Event triggers that should schedule a reload. Default
    ///     is `[.onDocumentEvents]` to match the JS default. Pass `[]` to
    ///     disable automatic reloads (you'll have to call `.reload()` yourself
    ///     after every mutation).
    ///   - load: The load closure. Receives the client; returns the data.
    ///     Errors thrown here are caught, stored on `error`, and forwarded to
    ///     `onError`. The closure is `@MainActor`-isolated (it runs on the
    ///     main actor, like the rest of this loader), so you can read
    ///     `@MainActor` state — e.g. a model read like
    ///     `try TaskRecord.findAll()` — directly, without wrapping it
    ///     in `await MainActor.run { … }`. (`find`/`findAll` are synchronous
    ///     throwing reads: throwing since js-bao-wss#992 — a stored row that
    ///     fails typed decode throws `PrimitiveDecodeError`, which this loader
    ///     surfaces on `error`/`onError` instead of silently dropping the row —
    ///     and synchronous since js-bao-wss#1156. The closure itself is still
    ///     `async` so it can also do genuinely async work like REST reads.)
    ///   - onError: Optional error callback (called in addition to setting
    ///     `error`).
    public func bind(
        client: JsBaoClient?,
        subscribeTo: [LoaderTrigger] = [.onDocumentEvents],
        load: @escaping @MainActor (JsBaoClient) async throws -> Data,
        onError: ((Error) -> Void)? = nil
    ) {
        // Tear down any prior binding before installing the new one.
        unbind()

        guard let client else { return }

        self.client = client
        self.loadClosure = load
        self.onErrorCallback = onError

        installSubscriptions(client: client, triggers: subscribeTo)

        if documentReady && !isPaused {
            scheduleReload()
        }
    }

    /// Tear down: cancel subscriptions, cancel any pending reload task, clear
    /// the load closure, reset published state.
    public func unbind() {
        for sub in subscriptions { sub.cancel() }
        subscriptions.removeAll()
        reloadTask?.cancel()
        reloadTask = nil
        loadGeneration &+= 1
        client = nil
        loadClosure = nil
        onErrorCallback = nil
        subscriptionsEnabled = false
        data = nil
        initialDataLoaded = false
        isLoading = false
        error = nil
        skeletonTimerTask?.cancel()
        skeletonTimerTask = nil
        skeletonDelayElapsed = false
        showSkeleton = false
    }

    // MARK: - Reload

    /// Schedule a debounced reload (debounced by `debounceInterval`). Coalesces
    /// rapid bursts; the load only runs `debounceInterval` after the most
    /// recent call.
    public func reload() {
        scheduleReload()
    }

    /// Reload immediately, bypassing debounce. Use this when you've just
    /// completed a write and want the latest state right now.
    public func reloadNow() {
        reloadTask?.cancel()
        Task { @MainActor in await performLoad() }
    }

    /// Drop the currently-loaded `data` (and any error) without tearing down
    /// the binding. Resets `initialDataLoaded` so the view falls back to its
    /// loading state.
    ///
    /// Use this when the *parameters* of what you're loading change — e.g.
    /// switching the selected database/document — and you want the UI to stop
    /// showing the previous result the instant the user switches, instead of
    /// hanging onto stale data until the next load lands.
    public func clear() {
        // Bump the generation so any in-flight load drops its result on the
        // floor instead of resurrecting the cleared state.
        loadGeneration &+= 1
        reloadTask?.cancel()
        reloadTask = nil
        data = nil
        error = nil
        initialDataLoaded = false
        subscriptionsEnabled = false
        isLoading = false
        disarmSkeletonTimer()
    }

    /// Reload immediately and wait for completion. Use this from button
    /// actions when you want the caller to know when the load has finished
    /// (e.g. so a `DemoButton` can keep its spinner visible until the data
    /// actually arrives).
    public func reloadNowAwaiting() async {
        reloadTask?.cancel()
        await performLoad()
    }

    private func scheduleReload() {
        guard documentReady, !isPaused, loadClosure != nil else { return }
        reloadTask?.cancel()
        // The debounce exists to coalesce bursts of *reactive* reloads (model
        // events). The FIRST load shouldn't pay it: delaying it 50ms is what
        // makes a `.loading` ProgressView flash before instantly-available
        // local CRDT data lands. Run load #0 immediately; debounce the rest.
        let delay = initialDataLoaded ? debounceInterval : 0
        reloadTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.performLoad()
        }
    }

    private func performLoad() async {
        guard documentReady, !isPaused else { return }
        guard let client, let load = loadClosure else { return }

        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        // Start the anti-flash timer only for the first load. If it completes
        // before `skeletonDelay`, `disarmSkeletonTimer()` below cancels the
        // timer and the skeleton never shows.
        if !initialDataLoaded { armSkeletonTimer() }

        do {
            let result = try await load(client)
            // If `unbind` (or another load) ran while we were awaiting, drop
            // this result on the floor — it's stale.
            guard generation == loadGeneration else { return }
            data = result
            error = nil
            if !initialDataLoaded {
                initialDataLoaded = true
                subscriptionsEnabled = true
            }
            disarmSkeletonTimer()
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error
            onErrorCallback?(error)
            // Stop the anti-flash timer on failure. If we left it armed (or
            // `skeletonDelayElapsed` already set), then — because a failed load
            // never sets `initialDataLoaded` — `showSkeleton` would compute to
            // `true` and stay stuck, hiding the error UI behind the skeleton.
            // Disarming clears the flag and refreshes `showSkeleton` to `false`
            // so the error surfaces. (This deliberately diverges from the JS
            // loader, which keeps the skeleton on error: Swift exposes a public
            // `error` flag, so the view should render the error, not a skeleton.)
            disarmSkeletonTimer()
        }

        isLoading = false
    }

    // MARK: - Document-ready transitions

    private func handleDocumentReadyChange() {
        if !documentReady {
            // Reset like the JS version does — re-binding to a fresh document
            // means re-running the initial load.
            initialDataLoaded = false
            subscriptionsEnabled = false
            reloadTask?.cancel()
            reloadTask = nil
            // The skeleton timer runs independently of `reloadTask`, so cancel
            // it too and clear `skeletonDelayElapsed`. Otherwise a timer still
            // armed from the interrupted load could fire against the previous
            // load's start time, or a leftover elapsed flag could make the next
            // load's skeleton appear immediately instead of after `skeletonDelay`.
            // `disarmSkeletonTimer()` also calls `refreshShowSkeleton()`, which
            // flips the skeleton on immediately here — while the document is
            // (re)opening no load runs yet, so the delay timer wouldn't cover
            // this wait.
            disarmSkeletonTimer()
            return
        }

        refreshShowSkeleton()
        if !isPaused, loadClosure != nil {
            scheduleReload()
        }
    }

    // MARK: - Anti-flash skeleton gating

    /// Recompute `showSkeleton` from the current state. Mirrors the JS
    /// `showSkeleton` computed:
    ///  - loaded             → never show
    ///  - document opening   → show immediately (`documentReady == false`)
    ///  - ready, still loading → show only after `skeletonDelay` elapsed
    private func refreshShowSkeleton() {
        let next: Bool
        if initialDataLoaded {
            next = false
        } else if !documentReady {
            next = true
        } else {
            next = skeletonDelayElapsed
        }
        if showSkeleton != next {
            showSkeleton = next
        }
    }

    /// Arm the skeleton-delay timer for a first load in flight. No-op if a
    /// timer is already running or the first load has already completed.
    private func armSkeletonTimer() {
        guard skeletonTimerTask == nil, !initialDataLoaded else { return }
        let delay = skeletonDelay
        skeletonTimerTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            self.skeletonTimerTask = nil
            guard !self.initialDataLoaded else { return }
            self.skeletonDelayElapsed = true
            self.refreshShowSkeleton()
        }
    }

    /// Cancel the skeleton-delay timer and clear the elapsed flag, then refresh
    /// `showSkeleton`. Called when a load completes and when state resets.
    private func disarmSkeletonTimer() {
        skeletonTimerTask?.cancel()
        skeletonTimerTask = nil
        skeletonDelayElapsed = false
        refreshShowSkeleton()
    }

    // MARK: - Subscriptions

    private func installSubscriptions(client: JsBaoClient, triggers: [LoaderTrigger]) {
        // `@Sendable` so it can be handed to the model-subscription triggers,
        // whose callbacks fire off the main thread (#1992). The body only
        // hops to the main actor, so it captures nothing thread-bound.
        let reloadAfterInitialLoad: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.subscriptionsEnabled else { return }
                guard self.documentReady, !self.isPaused else { return }
                self.scheduleReload()
            }
        }

        for trigger in triggers {
            switch trigger {
            case .onSync:
                let sub = client.observeOnMainActor(SyncEvent.self) { _ in
                    reloadAfterInitialLoad()
                }
                subscriptions.append(sub)

            case .onDocumentSyncStateChanged:
                let sub = client.observeOnMainActor(DocumentSyncStateChangedEvent.self) { event in
                    if event.state == "synced" {
                        reloadAfterInitialLoad()
                    }
                }
                subscriptions.append(sub)

            case .onDocumentEvents:
                let loadedSub = client.observeOnMainActor(DocumentLoadedEvent.self) { _ in
                    reloadAfterInitialLoad()
                }
                subscriptions.append(loadedSub)
                let closedSub = client.observeOnMainActor(DocumentClosedEvent.self) { _ in
                    reloadAfterInitialLoad()
                }
                subscriptions.append(closedSub)

            case .onConnect:
                let sub = client.observeOnMainActor(StatusChangedEvent.self) { event in
                    if event.status == .connected {
                        reloadAfterInitialLoad()
                    }
                }
                subscriptions.append(sub)

            case .onModelChange(let model):
                let unsubscribe = model.subscribe {
                    reloadAfterInitialLoad()
                }
                subscriptions.append(EventSubscription(cancel: unsubscribe))

            case .onModel(let subscribe):
                let unsubscribe = subscribe {
                    reloadAfterInitialLoad()
                }
                subscriptions.append(EventSubscription(cancel: unsubscribe))

            case .custom(let installer):
                if let sub = installer(client, reloadAfterInitialLoad) {
                    subscriptions.append(sub)
                }
            }
        }
    }
}
