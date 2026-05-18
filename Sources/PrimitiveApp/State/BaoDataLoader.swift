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
    /// Useful for `BaoModel<T>`-backed loaders.
    case onSync

    /// Reload on `JsBaoEvent.remoteUpdate` — fires whenever a remote write lands
    /// in any open document. Pair with `.onSync` for full BaoModel reactivity.
    case onRemoteUpdate

    /// Reload on `JsBaoEvent.documentLoaded` and `JsBaoEvent.documentClosed`.
    /// Matches the JS loader's `reloadOnDocumentEvents` flag (default on).
    case onDocumentEvents

    /// Reload when the connection status flips to `.connected`. Useful for
    /// REST-backed loaders that need to refresh after reconnect.
    case onConnect

    /// Caller-supplied subscription installer. Receive the connected client and
    /// a `reload` callback; install whatever event subscription you want and
    /// return it (or `nil` if you don't want to install anything). The loader
    /// holds the subscription and cancels it on `unbind` / deinit.
    case custom((JsBaoClient, @escaping () -> Void) -> EventSubscription?)
}

// MARK: - BaoDataLoader

/// Reactive data-loading helper modeled after the JS `useJsBaoDataLoader`
/// composable. Owns one piece of fetched data and the event subscriptions
/// that should cause it to refresh.
///
/// Generic over `Data` so callers pick the return shape — a single record,
/// `[T]`, a tuple/struct of derived values, anything. The `load` closure is
/// arbitrary, so the same loader works for `BaoModel<T>` records, raw REST
/// resources, or multi-source aggregations.
///
/// Differences from JS:
/// - Drops the second `Q` (queryParams) generic. Filter state lives in the
///   View as `@State`; trigger reloads from `.onChange(of:)`.
/// - `subscribeTo` takes a `[LoaderTrigger]` enum array instead of model
///   classes (Swift `BaoModel<T>` doesn't have JS's per-class pub/sub; the
///   equivalent reactivity is on `JsBaoClient.events`).
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

    // MARK: - Private state

    private weak var client: JsBaoClient?
    private var loadClosure: ((JsBaoClient) async throws -> Data)?
    private var onErrorCallback: ((Error) -> Void)?
    private var subscriptions: [EventSubscription] = []
    private var reloadTask: Task<Void, Never>?
    private var loadGeneration: Int = 0

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
    ///     `onError`.
    ///   - onError: Optional error callback (called in addition to setting
    ///     `error`).
    public func bind(
        client: JsBaoClient?,
        subscribeTo: [LoaderTrigger] = [.onDocumentEvents],
        load: @escaping (JsBaoClient) async throws -> Data,
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
        let delay = debounceInterval
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error
            onErrorCallback?(error)
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
            return
        }

        if !isPaused, loadClosure != nil {
            scheduleReload()
        }
    }

    // MARK: - Subscriptions

    private func installSubscriptions(client: JsBaoClient, triggers: [LoaderTrigger]) {
        let reloadAfterInitialLoad: () -> Void = { [weak self] in
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
                let sub = client.events.on(.sync) { (_: SyncEvent) in
                    reloadAfterInitialLoad()
                }
                subscriptions.append(sub)

            case .onRemoteUpdate:
                let sub = client.events.on(.remoteUpdate) { (_: RemoteUpdateEvent) in
                    reloadAfterInitialLoad()
                }
                subscriptions.append(sub)

            case .onDocumentEvents:
                let loadedSub = client.events.on(.documentLoaded) { (_: DocumentLoadedEvent) in
                    reloadAfterInitialLoad()
                }
                subscriptions.append(loadedSub)
                let closedSub = client.events.on(.documentClosed) { (_: DocumentClosedEvent) in
                    reloadAfterInitialLoad()
                }
                subscriptions.append(closedSub)

            case .onConnect:
                let sub = client.events.on(.status) { (event: StatusChangedEvent) in
                    if event.status == .connected {
                        reloadAfterInitialLoad()
                    }
                }
                subscriptions.append(sub)

            case .custom(let installer):
                if let sub = installer(client, reloadAfterInitialLoad) {
                    subscriptions.append(sub)
                }
            }
        }
    }
}
