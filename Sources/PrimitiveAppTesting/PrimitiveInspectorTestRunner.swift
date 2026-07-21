import Foundation
import PrimitiveApp

/// Headless runner for registered `InspectorTest`s — the Swift counterpart of
/// the JS vitest adapter (`registerPrimitiveTests` in
/// `packages/primitive-app/src/testing/index.ts`).
///
/// It runs the same `InspectorTest`s the in-app Debug Inspector panel runs, but
/// with no UI: given a host's registered tests, it executes each one against
/// whatever backend the tests were wired to (typically a client from
/// ``PrimitiveTestAuth/bootstrapClient(config:clientOptions:)``) and returns a
/// structured ``InspectorTestResult`` per test. It reports results instead of
/// asserting so it works from both XCTest and swift-testing without linking a
/// test framework into a shipped app library — the caller turns failures into
/// assertions:
///
/// ```swift
/// let results = await PrimitiveInspectorTestRunner.run(host: myHost)
/// print(results.summary)
/// for r in results.failures {
///     XCTFail("[\(r.id)] \(r.failureMessage ?? "failed")\n\(r.output)")
/// }
/// ```
///
/// Environment scoping mirrors the JS adapter: a test flagged for a different
/// context than the run is reported `.skipped`, not executed. The default run
/// context is `.headless`, so `.panel`-only tests are skipped (the analog of the
/// vitest adapter skipping JS `"browser"` tests).
@MainActor
public enum PrimitiveInspectorTestRunner {

    /// Default per-test timeout, in seconds. Matches the JS adapter's
    /// `testTimeoutMs` default (`60_000` ms) in
    /// `packages/primitive-app/src/testing/index.ts`.
    public nonisolated static let defaultTimeout: TimeInterval = 60

    /// Run a host's registered tests. Convenience over ``run(tests:environment:timeout:)``.
    public static func run(
        host: InspectorTestHost,
        environment: InspectorTestEnvironment = .headless,
        timeout: TimeInterval = defaultTimeout
    ) async -> [InspectorTestResult] {
        await run(tests: host.inspectorTests, environment: environment, timeout: timeout)
    }

    /// Run an explicit list of tests in `environment` (default `.headless`).
    ///
    /// A test whose own `environment` is set and differs from `environment` is
    /// skipped; an unscoped test (`environment == nil`) always runs. Failures
    /// are captured (thrown message + `TestContext` output) rather than
    /// propagated, so one failing test never aborts the rest of the run.
    ///
    /// Each test body is bounded by `timeout` seconds (default
    /// ``defaultTimeout``) for *asynchronous* hangs. A test suspended on an
    /// `await` that never resumes (an unresumed `withCheckedContinuation`, an
    /// awaited call or awaited I/O that never returns, a cancellable sleep) is
    /// reported as a failed ``InspectorTestResult`` ("timed out after Ns") and
    /// the run advances to the next test. The timeout does **not** bound a test
    /// that *synchronously* monopolizes the `@MainActor` — a tight CPU loop or
    /// a blocking syscall — which hangs the runner until its body returns; the
    /// CI-job-level timeout is the fallback for that case. See
    /// ``runWithTimeout(_:ctx:timeout:)`` for why.
    public static func run(
        tests: [InspectorTest],
        environment: InspectorTestEnvironment = .headless,
        timeout: TimeInterval = defaultTimeout
    ) async -> [InspectorTestResult] {
        var results: [InspectorTestResult] = []
        results.reserveCapacity(tests.count)

        for test in tests {
            if let scoped = test.environment, scoped != environment {
                results.append(InspectorTestResult(
                    id: test.id, group: test.group, name: test.name,
                    status: .skipped, durationMs: 0, output: "", failureMessage: nil
                ))
                continue
            }

            let ctx = TestContext()
            let started = Date()
            var status: InspectorTestResult.Status = .passed
            var failureMessage: String?
            do {
                try await runWithTimeout(test, ctx: ctx, timeout: timeout)
            } catch {
                status = .failed
                if let fail = error as? TestFailure {
                    failureMessage = fail.message
                } else {
                    failureMessage = String(describing: error)
                }
            }
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            results.append(InspectorTestResult(
                id: test.id, group: test.group, name: test.name,
                status: status, durationMs: durationMs,
                output: ctx.output, failureMessage: failureMessage
            ))
        }

        return results
    }

    /// Run one test body, racing it against a `timeout`-second deadline and
    /// returning as soon as either wins.
    ///
    /// The two are run as **unstructured** tasks and raced through a
    /// once-guarded continuation, so this returns the moment the first of them
    /// finishes — it never structurally awaits the loser. That is the guarantee
    /// a `withThrowingTaskGroup` cannot give: a group's scope does not exit
    /// until every child task has finished, and `cancelAll()` only *requests*
    /// cooperative cancellation. A test stalled on an `await` that never
    /// resumes (an unresumed `withCheckedContinuation`, an awaited call that
    /// never returns) would never observe the cancellation, so the group — and
    /// the whole runner — would hang forever; the unstructured race abandons
    /// that stalled task instead.
    ///
    /// **Scope of the guarantee.** This bounds *asynchronous* / cooperative
    /// hangs only — a stalled test that *suspends*, and so yields the
    /// `@MainActor`, letting the deadline task run and win the race. It cannot
    /// bound a test that *synchronously* monopolizes the actor: a tight CPU
    /// loop or a blocking syscall in a `@MainActor`-isolated test body never
    /// suspends, so nothing else scheduled on that executor — the deadline
    /// task, the continuation resumer — gets to run, and the timeout never
    /// fires. Such a test hangs the runner until its body returns; the
    /// CI-job-level timeout is the fallback for that case. This is the same
    /// limitation the JS adapter's per-test timeout has (`registerPrimitiveTests`
    /// in `packages/primitive-app/src/testing/index.ts`): a synchronous
    /// infinite loop blocks the single event-loop thread, and the timer that
    /// would report the timeout can't run until the loop yields.
    ///
    /// On the deadline the test task is cancelled (a best-effort request the
    /// test may ignore) and ``TestTimeout`` is thrown so the caller records a
    /// failed result and moves on. A test that suspended but ignores
    /// cancellation keeps running in the background: that stalled task is
    /// deliberately leaked — the accepted tradeoff, and the same one the JS
    /// adapter makes when it moves on and lets the losing promise dangle. On the
    /// normal path (the test wins) the deadline task is cancelled so it doesn't
    /// leak.
    private static func runWithTimeout(
        _ test: InspectorTest,
        ctx: TestContext,
        timeout: TimeInterval
    ) async throws {
        // Unstructured so the loser can be abandoned. The test body is
        // MainActor-isolated (matching `InspectorTest.run`); the runner is too —
        // which is why a test that synchronously monopolizes the actor (a tight
        // CPU loop / blocking syscall) can't be bounded here: it never yields
        // the executor to the deadline task. See the doc comment's "Scope of the
        // guarantee" — that case is CI-job-timeout territory.
        let testTask = Task { @MainActor in
            try await test.run(ctx)
        }
        let deadlineTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }

        // Whichever completes first resumes the continuation; the once-guard
        // makes the second completion a no-op so the continuation resumes
        // exactly once.
        let winner: RaceWinner = await withCheckedContinuation { cont in
            let resumer = OnceResumer(cont)
            Task {
                _ = await testTask.result
                resumer.resume(.test)
            }
            Task {
                // The deadline only "wins" when the sleep finishes normally;
                // if it was cancelled (the test won), stay silent.
                if case .success = await deadlineTask.result {
                    resumer.resume(.deadline)
                }
            }
        }

        switch winner {
        case .test:
            deadlineTask.cancel()
            // Already complete — rethrows the test's own error, if any.
            try await testTask.value
        case .deadline:
            testTask.cancel() // best-effort; a non-cooperative test ignores it and leaks
            throw TestTimeout(seconds: timeout)
        }
    }

    /// Which side of the ``runWithTimeout(_:ctx:timeout:)`` race finished first.
    private enum RaceWinner: Sendable { case test, deadline }

    /// Guards a `CheckedContinuation` so that only the first of two racing tasks
    /// resumes it; later calls are dropped. `CheckedContinuation` must be
    /// resumed exactly once.
    private final class OnceResumer: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<RaceWinner, Never>?
        init(_ cont: CheckedContinuation<RaceWinner, Never>) { self.cont = cont }
        func resume(_ winner: RaceWinner) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: winner)
        }
    }

    /// Thrown by ``runWithTimeout(_:ctx:timeout:)`` when a test exceeds its
    /// deadline. Its `description` becomes the failed result's message.
    private struct TestTimeout: Error, CustomStringConvertible {
        let seconds: TimeInterval
        var description: String { "timed out after \(String(format: "%g", seconds))s" }
    }
}
