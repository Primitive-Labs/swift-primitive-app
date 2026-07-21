import XCTest
@testable import PrimitiveApp
@testable import PrimitiveAppTesting

/// Offline coverage for the headless runner's core: pass/fail reporting,
/// output capture, and `environment` scoping. These use real `InspectorTest`
/// closures (no backend, no mocks) so they are deterministic and gate CI.
@MainActor
final class InspectorTestRunnerTests: XCTestCase {

    /// A minimal `InspectorTestHost` for exercising `run(host:)`.
    private final class Host: InspectorTestHost {
        var inspectorTests: [InspectorTest]
        init(_ tests: [InspectorTest]) { self.inspectorTests = tests }
    }

    // MARK: - Pass / fail reporting

    func test_passingTest_isReportedPassed() async {
        let tests = [
            InspectorTest(group: "G", name: "ok") { ctx in
                ctx.log("did a thing")
            }
        ]
        let results = await PrimitiveInspectorTestRunner.run(tests: tests)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .passed)
        XCTAssertEqual(results[0].id, "G::ok")
        XCTAssertTrue(results[0].output.contains("did a thing"))
        XCTAssertNil(results[0].failureMessage)
        XCTAssertTrue(results.allPassed)
    }

    func test_throwingTest_isReportedFailed_withMessageAndOutput() async {
        let tests = [
            InspectorTest(group: "G", name: "boom") { ctx in
                ctx.log("before failure")
                try ctx.check(false, "expected 1 == 2")
                ctx.log("unreached")
            }
        ]
        let results = await PrimitiveInspectorTestRunner.run(tests: tests)
        XCTAssertEqual(results[0].status, .failed)
        XCTAssertEqual(results[0].failureMessage, "expected 1 == 2")
        // Output logged before the throw is captured; nothing after it.
        XCTAssertTrue(results[0].output.contains("before failure"))
        XCTAssertFalse(results[0].output.contains("unreached"))
        XCTAssertFalse(results.allPassed)
        XCTAssertEqual(results.failures.count, 1)
    }

    func test_arbitraryThrownError_surfacesDescription() async {
        struct Boom: Error, CustomStringConvertible { var description: String { "kaboom" } }
        let tests = [
            InspectorTest(group: "G", name: "raw") { _ in throw Boom() }
        ]
        let results = await PrimitiveInspectorTestRunner.run(tests: tests)
        XCTAssertEqual(results[0].status, .failed)
        XCTAssertTrue(results[0].failureMessage?.contains("kaboom") == true)
    }

    func test_oneFailure_doesNotAbortRemainingTests() async {
        let tests = [
            InspectorTest(group: "G", name: "a") { _ in throw TestFailure(message: "nope") },
            InspectorTest(group: "G", name: "b") { ctx in ctx.log("ran b") },
        ]
        let results = await PrimitiveInspectorTestRunner.run(tests: tests)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].status, .failed)
        XCTAssertEqual(results[1].status, .passed)
    }

    func test_stalledTest_timesOut_andRunContinues() async {
        let tests = [
            InspectorTest(group: "G", name: "slow") { _ in
                // Far longer than the deadline below; cancelled on timeout.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            },
            InspectorTest(group: "G", name: "after") { ctx in ctx.log("ran after") },
        ]
        let results = await PrimitiveInspectorTestRunner.run(tests: tests, timeout: 0.2)
        XCTAssertEqual(results[0].status, .failed)
        XCTAssertTrue(results[0].failureMessage?.contains("timed out") == true)
        // A stalled test is bounded, so the run moves on rather than hanging.
        XCTAssertEqual(results[1].status, .passed)
        XCTAssertTrue(results[1].output.contains("ran after"))
    }

    /// A test **suspended** on an `await` that never resumes and ignores
    /// cancellation. Because it suspends, it yields the `@MainActor`, so the
    /// deadline task can run and win the race. The runner must still report it
    /// timed out and advance — it must not structurally await the stalled task
    /// (a `withThrowingTaskGroup` would hang here). The stalled task is leaked
    /// by design. This test's own short deadline + a hard XCTest timeout guard
    /// mean a regression surfaces as a failure, not a hung `swift test` process.
    ///
    /// This covers the *asynchronous* hang the timeout guarantees to bound. The
    /// complementary case — a test that *synchronously* monopolizes the
    /// `@MainActor` (a tight CPU loop or a blocking syscall) — is deliberately
    /// **not** unit-tested here: such a body never yields the executor, so the
    /// in-process deadline task can never run to report the timeout, and any
    /// test that reproduced it would itself hang `swift test`. That case is out
    /// of the runner's scope by design (see the runner's "Scope of the
    /// guarantee" doc comment) and is bounded by the CI-job-level timeout, not
    /// this per-test timeout — matching the JS adapter, whose per-test timer
    /// likewise cannot interrupt a synchronous event-loop hog.
    func test_nonCooperativeStall_timesOut_andRunContinues() async {
        let tests = [
            InspectorTest(group: "G", name: "stuck") { _ in
                // Awaits a continuation that is never resumed and ignores
                // cancellation — the classic hang the timeout must survive.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            },
            InspectorTest(group: "G", name: "after") { ctx in ctx.log("ran after") },
        ]
        let started = Date()
        let results = await PrimitiveInspectorTestRunner.run(tests: tests, timeout: 0.2)
        // The whole run returns promptly despite the un-cancellable stall.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].status, .failed)
        XCTAssertTrue(results[0].failureMessage?.contains("timed out") == true)
        XCTAssertEqual(results[1].status, .passed)
        XCTAssertTrue(results[1].output.contains("ran after"))
    }

    func test_run_viaHost_usesRegisteredTests() async {
        let host = Host([
            InspectorTest(group: "H", name: "one") { _ in }
        ])
        let results = await PrimitiveInspectorTestRunner.run(host: host)
        XCTAssertEqual(results.map(\.id), ["H::one"])
        XCTAssertEqual(results[0].status, .passed)
    }

    // MARK: - Environment scoping

    func test_headlessRun_skipsPanelOnly_runsHeadlessAndUnscoped() async {
        let tests = [
            InspectorTest(group: "G", name: "panel", environment: .panel) { _ in
                XCTFail("panel-only test must not run in a headless run")
            },
            InspectorTest(group: "G", name: "headless", environment: .headless) { ctx in ctx.log("ran") },
            InspectorTest(group: "G", name: "both") { ctx in ctx.log("ran") },
        ]
        let results = await PrimitiveInspectorTestRunner.run(tests: tests, environment: .headless)
        XCTAssertEqual(results[0].status, .skipped)
        XCTAssertEqual(results[1].status, .passed)
        XCTAssertEqual(results[2].status, .passed)
        // A skip is neither a pass nor a failure.
        XCTAssertTrue(results.allPassed)
        XCTAssertEqual(results.filter { $0.skipped }.count, 1)
    }

    func test_panelRun_skipsHeadlessOnly() async {
        let tests = [
            InspectorTest(group: "G", name: "headless", environment: .headless) { _ in
                XCTFail("headless-only test must not run in a panel run")
            },
            InspectorTest(group: "G", name: "panel", environment: .panel) { ctx in ctx.log("ran") },
        ]
        let results = await PrimitiveInspectorTestRunner.run(tests: tests, environment: .panel)
        XCTAssertEqual(results[0].status, .skipped)
        XCTAssertEqual(results[1].status, .passed)
    }

    func test_summary_countsEachOutcome() async {
        let tests = [
            InspectorTest(group: "G", name: "p") { _ in },
            InspectorTest(group: "G", name: "f") { _ in throw TestFailure(message: "x") },
            InspectorTest(group: "G", name: "s", environment: .panel) { _ in },
        ]
        let results = await PrimitiveInspectorTestRunner.run(tests: tests, environment: .headless)
        XCTAssertEqual(results.summary, "1 passed, 1 failed, 1 skipped")
    }
}
