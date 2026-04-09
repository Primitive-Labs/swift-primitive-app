import XCTest
@testable import PrimitiveApp
import JsBaoClient

/// Tests for `BaoDataLoader`'s generation counter — the only piece of subtle
/// state in the loader. The counter exists to drop stale results when a load
/// is in flight and the loader is reloaded, cleared, or unbound underneath
/// it. If those guards regress, an old `findAll()` snapshot can win the race
/// and overwrite a fresh one — exactly the kind of bug that won't show up
/// in the demo until a user moves fast.
///
/// These tests don't touch the network. The loader's `load` closure is
/// arbitrary, so we hand it a sleep+counter and watch what `data` ends up
/// holding.
@MainActor
final class BaoDataLoaderTests: XCTestCase {

    /// Build a JsBaoClient that can be passed to `bind(...)` without doing
    /// any IO. We never call `connect()`, so the apiUrl/wsUrl values just
    /// have to parse — no server actually hears about us.
    private func makeTestClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "https://example.invalid",
            wsUrl: "wss://example.invalid",
            appId: "test-app",
            offline: false,
            logLevel: .warn,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    /// Two loads in flight at once: only the second one's result should
    /// land in `data`. We wait until call 1 is actually running before
    /// firing call 2 — without the generation guard, call 1's slower
    /// result would clobber call 2's newer one when it finally returned.
    func testStaleLoadDroppedOnReloadRace() async throws {
        let loader = BaoDataLoader<Int>()
        // BaoDataLoader holds the client weakly — the test must keep its
        // own strong reference or the loader's `guard let client` short
        // circuits before the load closure can ever run.
        let client = makeTestClient()
        // Skip the 50ms debounce so the bind-triggered load fires
        // immediately and we don't race the test's own waits.
        loader.debounceInterval = 0
        let callCount = TestCounter()
        let firstCallStarted = TestFlag()

        loader.bind(
            client: client,
            subscribeTo: []
        ) { _ in
            let myCall = await callCount.increment()
            if myCall == 1 {
                // Hold call 1 in flight long enough for the test to fire
                // call 2 before call 1 returns.
                await firstCallStarted.set()
                try await Task.sleep(nanoseconds: 200_000_000)
            } else {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return myCall
        }

        // Wait for the bind-triggered load to actually be running before
        // we fire the second one — otherwise reloadNow could cancel the
        // first task before it ever ran and we'd only see one call.
        for _ in 0..<40 {
            if await firstCallStarted.value { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let started = await firstCallStarted.value
        XCTAssertTrue(started, "Call 1 should be in flight before we kick call 2")

        loader.reloadNow()

        // Wait long enough for both calls to settle (well past call 1's
        // 200ms sleep).
        try await Task.sleep(nanoseconds: 400_000_000)

        let count = await callCount.value
        XCTAssertEqual(count, 2, "Both loads should have run")
        XCTAssertEqual(loader.data, 2, "Newer load should win, stale call 1 must be dropped")

        loader.unbind()
    }

    /// Calling `clear()` while a load is in flight should bump the generation
    /// so the in-flight load's result lands on the floor instead of resetting
    /// `data` back to a stale value. This is the "user switched the
    /// selected database" scenario.
    func testClearDropsInFlightLoad() async throws {
        let loader = BaoDataLoader<String>()
        let client = makeTestClient()
        loader.debounceInterval = 0
        let started = TestFlag()

        loader.bind(
            client: client,
            subscribeTo: []
        ) { _ in
            await started.set()
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            return "stale-result"
        }

        // Yield until the load is actually running, otherwise we'd race
        // bind→clear and never exercise the in-flight path.
        for _ in 0..<40 {
            if await started.value { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let didStart = await started.value
        XCTAssertTrue(didStart, "Load should have started before clear()")

        loader.clear()

        // Wait past the closure's sleep so it would have set `data` if the
        // generation guard wasn't doing its job.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(loader.data, "Cleared loader must not be repopulated by an in-flight load")
        XCTAssertFalse(loader.initialDataLoaded, "Cleared loader should not flip initialDataLoaded")

        loader.unbind()
    }

    /// `unbind()` mid-flight should also drop the in-flight result. This is
    /// the SwiftUI `.onDisappear { loader.unbind() }` cleanup path — if the
    /// guard is missing here, the loader fires a published-property change
    /// after the view's gone.
    func testUnbindDropsInFlightLoad() async throws {
        let loader = BaoDataLoader<Int>()
        let client = makeTestClient()
        loader.debounceInterval = 0
        let started = TestFlag()

        loader.bind(
            client: client,
            subscribeTo: []
        ) { _ in
            await started.set()
            try await Task.sleep(nanoseconds: 100_000_000)
            return 42
        }

        for _ in 0..<40 {
            if await started.value { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let didStart = await started.value
        XCTAssertTrue(didStart)

        loader.unbind()

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(loader.data, "Unbound loader must not be repopulated by an in-flight load")
    }

    /// `documentReady = false` should also tear down the in-flight state.
    /// Setting it back to `true` is what fires a fresh load, so the
    /// generation needs to be advanced to keep the old result out.
    func testDocumentReadyFalseDropsLoad() async throws {
        let loader = BaoDataLoader<Int>()
        let client = makeTestClient()
        loader.debounceInterval = 0
        let started = TestFlag()

        loader.bind(
            client: client,
            subscribeTo: []
        ) { _ in
            await started.set()
            try await Task.sleep(nanoseconds: 100_000_000)
            return 1
        }

        for _ in 0..<40 {
            if await started.value { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        loader.documentReady = false

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(loader.initialDataLoaded, "Going not-ready should reset initialDataLoaded")

        loader.unbind()
    }
}

// MARK: - Test helpers

/// Tiny actor-based counter for tests. The load closure crosses the
/// MainActor boundary, so we can't capture a plain `var` without
/// concurrency-checking complaints.
private actor TestCounter {
    private var count = 0
    var value: Int { count }
    func increment() -> Int {
        count += 1
        return count
    }
}

private actor TestFlag {
    private var flag = false
    var value: Bool { flag }
    func set() { flag = true }
}
