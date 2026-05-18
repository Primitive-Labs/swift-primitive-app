#if DEBUG
import Foundation
import os

// Unified-logging channel for every inspector-side message. Using `Logger`
// (not `print`) is critical on iOS: `print()` writes to the process's
// stdout, which `xcrun simctl spawn … log stream` does NOT capture. Going
// through os_log under the existing `com.primitivelabs.PrimitiveApp`
// subsystem means run-ios.sh's default filter surfaces the banner +
// inspector-internal logs alongside the rest of the app's messages.
private let logger = Logger(subsystem: "com.primitivelabs.PrimitiveApp", category: "Inspector")

/// Ring buffer of recent inspector-internal log lines. The inspector exposes this at
/// `GET /api/logs` so dev can tail it from the browser without grepping Console.app.
///
/// `inspectorLog(_)` both appends to the buffer AND emits through the os_log channel
/// above, so everything stays visible in the device log as well.
final class InspectorLog: @unchecked Sendable {
    static let shared = InspectorLog()

    private let lock = NSLock()
    private var lines: [[String: Any]] = []
    private let maxLines = 500
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func write(_ message: String, level: String = "info") {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let line: [String: Any] = ["ts": ts, "level": level, "message": message]
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
        // Route through os_log so iOS Simulator `log stream`, Console.app on macOS,
        // and Xcode's built-in console all pick it up under the existing subsystem.
        switch level {
        case "error": logger.error("\(message, privacy: .public)")
        case "warn":  logger.warning("\(message, privacy: .public)")
        default:      logger.info("\(message, privacy: .public)")
        }
    }

    func snapshot() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

/// Shorthand used throughout the Debug module. Every observable failure (action error,
/// listener state change, 404-routing miss) goes through this so the Logs tab shows a
/// complete picture of what the inspector has been doing.
func inspectorLog(_ message: String, level: String = "info") {
    InspectorLog.shared.write(message, level: level)
}
#endif
