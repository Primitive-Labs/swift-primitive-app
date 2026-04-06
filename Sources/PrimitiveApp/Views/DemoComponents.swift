import SwiftUI

// MARK: - PrimitiveCard

/// A card container with an optional title, rounded corners, and a subtle border.
///
/// Use it to visually group related content in a feature section.
///
/// ```swift
/// PrimitiveCard(title: "Settings") {
///     Toggle("Notifications", isOn: $enabled)
/// }
/// ```
public struct PrimitiveCard<Content: View>: View {
    private let title: String?
    private let content: () -> Content

    /// Creates a card view.
    /// - Parameters:
    ///   - title: An optional header displayed above the card content.
    ///   - content: The views to display inside the card.
    public init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    /// Platform-appropriate card background color.
    private var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

// MARK: - PrimitiveSectionHeader

/// A section header with a leading SF Symbol icon and a title.
///
/// ```swift
/// PrimitiveSectionHeader(icon: "gearshape", title: "Configuration")
/// ```
public struct PrimitiveSectionHeader: View {
    private let icon: String
    private let title: String

    /// Creates a section header.
    /// - Parameters:
    ///   - icon: An SF Symbols name for the leading icon.
    ///   - title: The section title.
    public init(icon: String, title: String) {
        self.icon = icon
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .imageScale(.medium)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .padding(.top, 8)
    }
}

// MARK: - PrimitiveCodeBlock

/// Displays text in a monospaced font on a rounded gray background.
///
/// Ideal for showing code snippets, command output, or JSON responses.
///
/// ```swift
/// PrimitiveCodeBlock("let x = 42\nprint(x)")
/// ```
public struct PrimitiveCodeBlock: View {
    private let text: String

    /// Creates a code block.
    /// - Parameter text: The text to display.
    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - PrimitiveActionButton

/// An async action button that shows a loading spinner while its action is running.
///
/// Modelled after the demo app's `DemoButton` but exposed as a public library component.
///
/// ```swift
/// PrimitiveActionButton("Fetch Data", icon: "arrow.down") {
///     try await api.fetchData()
/// }
/// ```
public struct PrimitiveActionButton: View {
    private let label: String
    private let icon: String
    private let disabled: Bool
    private let action: () async -> Void

    @State private var isRunning = false

    /// Creates an async action button.
    /// - Parameters:
    ///   - label: The button title.
    ///   - icon: An SF Symbols name shown to the left of the label.
    ///   - disabled: Whether the button is disabled independent of the running state.
    ///   - action: The async closure to execute when tapped.
    public init(
        _ label: String,
        icon: String,
        disabled: Bool = false,
        action: @escaping () async -> Void
    ) {
        self.label = label
        self.icon = icon
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        Button {
            Task {
                isRunning = true
                await action()
                isRunning = false
            }
        } label: {
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                }
                Text(label)
            }
            .font(.subheadline)
        }
        .disabled(disabled || isRunning)
    }
}

// MARK: - PrimitiveOutputConsole

/// A scrollable output console for displaying lines of text, styled like a terminal.
///
/// Lines starting with `">"` are highlighted with primary foreground color;
/// all other lines use secondary styling.
///
/// ```swift
/// @State private var output: [String] = []
///
/// PrimitiveOutputConsole(lines: output)
/// ```
public struct PrimitiveOutputConsole: View {
    private let lines: [String]
    private let maxHeight: CGFloat

    /// Creates an output console.
    /// - Parameters:
    ///   - lines: The text lines to display.
    ///   - maxHeight: The maximum height before the console scrolls. Defaults to 300.
    public init(lines: [String], maxHeight: CGFloat = 300) {
        self.lines = lines
        self.maxHeight = maxHeight
    }

    public var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(lines.count) \(lines.count == 1 ? "line" : "lines")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.hasPrefix(">") ? .primary : .secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxHeight)
            }
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
            )
        }
    }
}
