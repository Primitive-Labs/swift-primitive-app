// Always compiled (no `#if DEBUG` wrapper) so apps can reference the types when declaring
// their test suites. The runtime that actually invokes tests lives in DebugInspector.swift
// and is `#if DEBUG`-only, so release builds never run any of this.
import Foundation

/// A single test case surfaced to the inspector.
///
/// Tests are pure Swift closures that accept a `TestContext` for logging and assertions.
/// Throw anything to signal failure — the inspector captures the error message. Tests run
/// on the main actor, same as the rest of `PrimitiveAppState`, so they can touch
/// `@MainActor`-isolated state (client, BaoModels, app state) without dancing.
public struct InspectorTest: @unchecked Sendable {
    public let group: String
    public let name: String
    public let run: @MainActor (TestContext) async throws -> Void

    public init(
        group: String = "Default",
        name: String,
        run: @escaping @MainActor (TestContext) async throws -> Void
    ) {
        self.group = group
        self.name = name
        self.run = run
    }

    /// Stable identifier used as a map key in the inspector UI and as the `id` field in
    /// POST /api/action/test/run. `group::name` is unique within an app because the
    /// inspector de-dupes by this string.
    public var id: String { "\(group)::\(name)" }
}

/// Logging + assertion helper passed to every `InspectorTest.run` closure.
///
/// Thread-safe across the test's execution (all its mutating calls are guarded) so tests
/// can spawn Tasks that log concurrently. Output is accumulated into a single string that
/// the inspector shows in the output pane at the end of the run.
public final class TestContext: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let startedAt: Date = Date()

    public init() {}

    /// Milliseconds since this context was created. Useful for building your own timing
    /// traces ("step X: 140ms since start") inside a test body.
    public var elapsedMs: Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

    /// Append a line to the test's output. The inspector renders lines verbatim.
    public func log(_ msg: String) {
        let stamped = "[+\(String(format: "%4d", elapsedMs))ms] \(msg)"
        lock.lock(); lines.append(stamped); lock.unlock()
    }

    /// Throw `TestFailure` if `condition` is false. Preferable to raw `precondition` because
    /// the failure message ends up in the inspector output pane instead of crashing the app.
    public func check(_ condition: Bool, _ message: @autoclosure () -> String = "check failed") throws {
        if !condition { throw TestFailure(message: message()) }
    }

    /// Snapshot of all logged lines. Called by the runner after the test completes.
    public var output: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// A `TestContext.check` failure. The inspector surfaces `message` in the output pane and
/// marks the test as failed. Apps can also throw any other `Error` — its `localizedDescription`
/// gets captured the same way.
public struct TestFailure: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// Opt-in for a `PrimitiveAppState` subclass to expose its test suite to the inspector.
///
/// The inspector calls `inspectorTests` once per `/api/tests` GET, so registration is
/// dynamic — you can grow the list based on feature flags, current user, etc. Returning
/// `[]` hides the Tests tab in the UI.
public protocol InspectorTestHost: AnyObject {
    @MainActor var inspectorTests: [InspectorTest] { get }
}
