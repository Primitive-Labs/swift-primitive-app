// Always compiled (no `#if DEBUG` wrapper) so apps can reference the types when declaring
// their custom action / route surface. The runtime that actually invokes them lives in
// DebugInspector.swift and is `#if DEBUG`-only, so release builds never run any of this.
import Foundation

/// A custom action surfaced to the inspector's `POST /api/action/<name>` dispatcher.
///
/// Apps register actions by conforming their `PrimitiveAppState` subclass to
/// `InspectorActionHost`. The dispatcher checks built-in action names first
/// (`doc/share`, `col/create`, etc.), then falls through to any matching custom
/// action. Built-ins always win on collision — name your custom actions with an
/// app-specific prefix (`appstate/foo`, `myapp/bar`, `fixtures/baz`) to avoid
/// future framework collisions.
///
/// Handlers run on the main actor and can throw to signal failure. Thrown errors
/// flow through the same `HttpError` / `JsBaoError` / generic `Error` catch
/// arms in `DebugInspector.dispatchAction`, so the response shape (with `ok:
/// false`, structured error fields) matches built-in actions.
public struct InspectorAction: @unchecked Sendable {
    public let name: String
    public let handler: @MainActor (_ body: [String: Any]) async throws -> [String: Any]

    public init(
        name: String,
        handler: @escaping @MainActor (_ body: [String: Any]) async throws -> [String: Any]
    ) {
        self.name = name
        self.handler = handler
    }
}

/// A custom GET route surfaced under `/api/...`.
///
/// Use for read-only endpoints that don't fit the model-row / SQL-query shape the
/// inspector already exposes — typically derived view-state structs (e.g. "what
/// would the library screen render given filter X?"). Handlers receive the
/// query-string dict and return any JSON-serializable value (Dictionary, Array,
/// or scalar).
///
/// Path is matched verbatim and must start with `/api/`. Built-in routes
/// (`/api/snapshot`, `/api/models`, etc.) take precedence; collisions are
/// silently won by the built-ins.
public struct InspectorRoute: @unchecked Sendable {
    public let path: String
    public let handler: @MainActor (_ query: [String: String]) async throws -> Any

    public init(
        path: String,
        handler: @escaping @MainActor (_ query: [String: String]) async throws -> Any
    ) {
        self.path = path
        self.handler = handler
    }
}

/// Opt-in for a `PrimitiveAppState` subclass to expose custom actions to the inspector.
///
/// The inspector calls `inspectorActions` on every action dispatch (no caching), so the
/// list can be dynamic — feature-flag actions, user-scope them, etc. Returning `[]` is
/// equivalent to not conforming at all.
public protocol InspectorActionHost: AnyObject {
    @MainActor var inspectorActions: [InspectorAction] { get }
}

/// Opt-in for a `PrimitiveAppState` subclass to expose custom GET routes to the inspector.
///
/// Same dynamic-evaluation contract as `InspectorActionHost`. Returning `[]` is equivalent
/// to not conforming at all.
public protocol InspectorRouteHost: AnyObject {
    @MainActor var inspectorRoutes: [InspectorRoute] { get }
}
