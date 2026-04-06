import SwiftUI

// MARK: - Theme Manager

/// Manages theme preferences (dark mode and accent color) with UserDefaults persistence.
///
/// Usage:
/// ```swift
/// @StateObject private var theme = PrimitiveThemeManager()
///
/// ContentView()
///     .environmentObject(theme)
/// ```
public final class PrimitiveThemeManager: ObservableObject {

    // MARK: UserDefaults keys

    private enum Keys {
        static let isDarkMode = "PrimitiveTheme.isDarkMode"
        static let accentColorName = "PrimitiveTheme.accentColorName"
    }

    // MARK: Published properties

    /// Whether dark mode is active. Persisted across launches.
    @Published public var isDarkMode: Bool {
        didSet { UserDefaults.standard.set(isDarkMode, forKey: Keys.isDarkMode) }
    }

    /// The name of the current accent color.
    /// Valid values: `"blue"`, `"teal"`, `"orange"`, `"purple"`, `"green"`.
    @Published public var accentColorName: String {
        didSet { UserDefaults.standard.set(accentColorName, forKey: Keys.accentColorName) }
    }

    // MARK: Supported colors

    /// All accent color names the manager recognizes.
    public static let supportedColorNames: [String] = [
        "blue", "teal", "orange", "purple", "green"
    ]

    private static let colorMap: [String: Color] = [
        "blue": .blue,
        "teal": .teal,
        "orange": .orange,
        "purple": .purple,
        "green": .green
    ]

    // MARK: Computed

    /// The SwiftUI `Color` corresponding to `accentColorName`.
    /// Falls back to `.blue` if the name is unrecognized.
    public var accentColor: Color {
        Self.colorMap[accentColorName] ?? .blue
    }

    /// The preferred color scheme derived from `isDarkMode`.
    public var preferredColorScheme: ColorScheme {
        isDarkMode ? .dark : .light
    }

    // MARK: Init

    /// Creates a new theme manager, loading persisted values from UserDefaults.
    public init() {
        let defaults = UserDefaults.standard

        // isDarkMode defaults to false (light mode) when no value has been stored.
        self.isDarkMode = defaults.bool(forKey: Keys.isDarkMode)

        // accentColorName defaults to "blue" when no value has been stored.
        let stored = defaults.string(forKey: Keys.accentColorName) ?? "blue"
        self.accentColorName = Self.colorMap.keys.contains(stored) ? stored : "blue"
    }

    // MARK: Actions

    /// Toggles between light and dark mode.
    public func toggleDarkMode() {
        isDarkMode.toggle()
    }

    /// Sets the accent color by name.
    ///
    /// If the provided name is not one of the supported values the call is ignored.
    /// - Parameter name: One of `"blue"`, `"teal"`, `"orange"`, `"purple"`, `"green"`.
    public func setAccentColor(_ name: String) {
        guard Self.colorMap.keys.contains(name) else { return }
        accentColorName = name
    }
}

// MARK: - Theme Wrapper View

/// A wrapper view that applies the preferred color scheme from a `PrimitiveThemeManager`.
///
/// Usage:
/// ```swift
/// @StateObject private var theme = PrimitiveThemeManager()
///
/// PrimitiveThemeView {
///     ContentView()
/// }
/// .environmentObject(theme)
/// ```
public struct PrimitiveThemeView<Content: View>: View {
    @EnvironmentObject private var theme: PrimitiveThemeManager

    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        content()
            .preferredColorScheme(theme.preferredColorScheme)
            .tint(theme.accentColor)
    }
}
