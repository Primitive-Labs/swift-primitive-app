import Foundation

/// Outcome of one registered `InspectorTest` under the headless runner.
public struct InspectorTestResult: Sendable {
    public enum Status: String, Sendable {
        case passed
        case failed
        /// Scoped to a different `environment` than the run — not executed.
        case skipped
    }

    /// `group::name`, matching `InspectorTest.id`.
    public let id: String
    public let group: String
    public let name: String
    public let status: Status
    /// Wall-clock duration of the run in milliseconds (0 for skipped).
    public let durationMs: Int
    /// Everything the test logged via `TestContext.log`.
    public let output: String
    /// The thrown error's message when `status == .failed`; `nil` otherwise.
    public let failureMessage: String?

    public var passed: Bool { status == .passed }
    public var failed: Bool { status == .failed }
    public var skipped: Bool { status == .skipped }
}

public extension Array where Element == InspectorTestResult {
    /// Tests that ran and failed.
    var failures: [InspectorTestResult] { filter { $0.failed } }

    /// True when nothing that ran failed (skips don't count against it).
    var allPassed: Bool { !contains { $0.failed } }

    /// One-line "N passed, M failed, K skipped" tally, useful for CI logs.
    var summary: String {
        let passed = filter { $0.passed }.count
        let failed = filter { $0.failed }.count
        let skipped = filter { $0.skipped }.count
        return "\(passed) passed, \(failed) failed, \(skipped) skipped"
    }
}
