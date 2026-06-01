import SwiftUI

/// Renders its content only once an awaited value is available, showing a
/// placeholder until then.
///
/// This is the idiomatic answer to a very common Primitive lifecycle
/// shape: the things a screen reads — `appState.someModel`, an
/// `openAuxiliaryDoc` result, anything bound after `connectClient` /
/// `onDocumentOpened` — are `nil` for the first beat after launch
/// because opening the backing document is a network round-trip. A
/// screen that reads them on `.onAppear` / `.task` sees `nil`, and the
/// naive
///
/// ```swift
/// .task {
///     guard let model = appState.model else { return }   // bails on first appear
///     loader.bind(client: appState.client, subscribeTo: [.onModelChange(model)]) { … }
/// }
/// ```
///
/// silently never binds (the `.task` runs once, before the value
/// arrives, and doesn't re-run) — leaving the screen stuck on a spinner
/// until the view happens to be rebuilt. `ReadyGate` removes the trap by
/// only mounting the content **after** the value is non-`nil`, so the
/// content can read it unconditionally:
///
/// ```swift
/// ReadyGate(appState.model) { model in
///     MyScreen()        // mounted only once `model` exists; no readiness
///                       // ceremony, no `.task(id:)`, no guard-that-bails
/// }
/// ```
///
/// Gate **once, as high as makes sense** (e.g. wrapping a tab's root)
/// and every screen below it can be written assuming its data is ready.
/// Because `value` is read in `body`, the gate re-evaluates whenever the
/// owning `ObservableObject` publishes — so the content appears the
/// instant the value flips from `nil` to non-`nil`.
///
/// The default placeholder is a centered `ProgressView`; supply your own
/// with the two-closure initializer.
public struct ReadyGate<Value, Content: View, Placeholder: View>: View {
    private let value: Value?
    private let content: (Value) -> Content
    private let placeholder: () -> Placeholder

    /// - Parameters:
    ///   - value: The awaited optional. While `nil`, `placeholder` shows;
    ///     once non-`nil`, `content` is mounted with the unwrapped value.
    ///   - content: Builds the ready UI from the unwrapped value.
    ///   - placeholder: Shown while `value` is `nil`.
    public init(
        _ value: Value?,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.value = value
        self.content = content
        self.placeholder = placeholder
    }

    public var body: some View {
        if let value {
            content(value)
        } else {
            placeholder()
        }
    }
}

public extension ReadyGate where Placeholder == ReadyGateProgress {
    /// Convenience using the default centered `ProgressView` placeholder.
    init(_ value: Value?, @ViewBuilder content: @escaping (Value) -> Content) {
        self.init(value, content: content, placeholder: { ReadyGateProgress() })
    }
}

/// The default `ReadyGate` placeholder: a `ProgressView` centered in the
/// available space.
public struct ReadyGateProgress: View {
    public init() {}
    public var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
