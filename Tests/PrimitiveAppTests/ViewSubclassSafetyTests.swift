import XCTest
import SwiftUI
@testable import PrimitiveApp

/// Regression guard for the `@EnvironmentObject var appState: PrimitiveAppState`
/// crash the built-in views used to have. Apps subclassing
/// `PrimitiveAppState` (the documented canonical pattern) would inject the
/// subclass via `.environmentObject(...)`. SwiftUI keys the environment by
/// runtime type, so the views' `@EnvironmentObject var appState: PrimitiveAppState`
/// lookup missed and trapped on first body access — producing
/// "Application Quit Unexpectedly" before any UI rendered.
///
/// The fix: built-in views take `appState` via init parameter and observe it
/// via `@ObservedObject`. This test exercises the explicit-parameter init
/// against a SUBCLASS of `PrimitiveAppState`. If someone regresses one of
/// these views back to `@EnvironmentObject` (and removes the `appState:`
/// init parameter), the test below stops compiling — surfacing the
/// regression at `swift test` time instead of at `simctl launch` time.
@MainActor
final class ViewSubclassSafetyTests: XCTestCase {

    /// Minimal subclass of `PrimitiveAppState`. Stands in for the
    /// `MyAppState`/`TemplateAppState` shape the agent guide steers
    /// app authors toward.
    final class TestAppState: PrimitiveAppState {}

    func testAuthGateViewTakesAppStateExplicitly() {
        let state = TestAppState()
        _ = AuthGateView(
            appState: state,
            appName: "test",
            authManager: state.authManager
        ) {
            Text("content")
        }
    }

    func testConnectionStatusViewTakesAppStateExplicitly() {
        let state = TestAppState()
        _ = ConnectionStatusView(appState: state)
    }

    func testDocumentSidebarViewTakesAppStateExplicitly() {
        let state = TestAppState()
        _ = DocumentSidebarView(appState: state)
    }

    func testPrimitiveProfileViewTakesAppStateExplicitly() {
        let state = TestAppState()
        _ = PrimitiveProfileView(
            appState: state,
            authManager: state.authManager
        )
    }
}
