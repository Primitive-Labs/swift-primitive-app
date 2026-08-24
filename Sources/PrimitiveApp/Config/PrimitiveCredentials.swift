import Foundation
import os

private let logger = Logger(subsystem: "com.primitivelabs.PrimitiveApp", category: "Config")

/// App configuration loaded from `primitive.json`.
///
/// `primitive.json` is a BUILD PRODUCT, not a tracked file: the app ID and
/// server URL are typed once in `.primitive/config.json`, and
/// `scripts/resolve-primitive-config.sh` writes the selected Primitive
/// environment's values into this shape before every build. Never hand-edit
/// it — change the environment instead (`primitive env use <name>`).
public struct PrimitiveAppConfig {
    public let appId: String
    public let appName: String
    public let serverUrl: String

    public init(appId: String, appName: String, serverUrl: String = "https://primitiveapi.com") {
        self.appId = appId
        self.appName = appName
        self.serverUrl = serverUrl
    }

    /// The WebSocket URL derived from the server URL.
    public var wsUrl: String {
        serverUrl
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
    }
}

/// Loads app config from a `primitive.json` file.
///
/// Search order: caller-provided paths, then CWD, then app bundle.
public func loadPrimitiveAppConfig(
    searchPaths: [URL] = []
) -> Result<PrimitiveAppConfig, PrimitiveConfigError> {
    let fm = FileManager.default

    var candidates = searchPaths
    // CWD (works for ./run.sh command-line builds)
    candidates.append(
        URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("primitive.json")
    )
    // App bundle (works for Xcode builds and iOS simulator)
    if let bundled = Bundle.main.url(forResource: "primitive", withExtension: "json") {
        candidates.append(bundled)
    }

    for (i, path) in candidates.enumerated() {
        let exists = fm.fileExists(atPath: path.path)
        logger.debug("primitive.json candidate[\(i)]: \(path.path) exists=\(exists)")
    }

    guard let configPath = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
        logger.error("primitive.json not found in any candidate path")
        return .failure(.noAppConfig)
    }
    logger.info("Loading primitive.json from: \(configPath.path)")

    guard let data = try? Data(contentsOf: configPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let appId = json["appId"] as? String else {
        return .failure(.noAppConfig)
    }

    let appName = json["appName"] as? String ?? appId
    let serverUrl = json["serverUrl"] as? String ?? "https://primitiveapi.com"

    return .success(PrimitiveAppConfig(appId: appId, appName: appName, serverUrl: serverUrl))
}

/// Errors that can occur when loading app config.
public enum PrimitiveConfigError: Error, CustomStringConvertible {
    case noAppConfig

    public var description: String {
        switch self {
        case .noAppConfig:
            return """
                No primitive.json found. It is generated from the Primitive \
                environment selected in .primitive/config.json — run \
                `bash scripts/resolve-primitive-config.sh` (run.sh, run-ios.sh, \
                archive.sh and the Xcode pre-build phase all do this for you).
                """
        }
    }
}

// MARK: - Local dev env file

/// Loads a local `.env.local` file (or any of the caller-supplied search
/// paths) into a `[key: value]` dict. Used for dev-only toggles that
/// should never be committed to git.
///
/// Format: standard `KEY=VALUE` lines, one per line. Lines starting with
/// `#` are comments. Surrounding single/double quotes on values are
/// stripped. No interpolation, no multiline values — kept deliberately
/// simple because this is for a handful of dev toggles, not a full env
/// system.
///
/// Returns an empty dict if no file is found. The CWD is always checked
/// last, so caller-supplied paths take precedence.
public func loadPrimitiveDevEnv(searchPaths: [URL] = []) -> [String: String] {
    let fm = FileManager.default
    var candidates = searchPaths
    candidates.append(
        URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".env.local")
    )

    guard let path = candidates.first(where: { fm.fileExists(atPath: $0.path) }),
          let contents = try? String(contentsOf: path, encoding: .utf8) else {
        return [:]
    }

    logger.debug("Loaded dev env from: \(path.path)")

    var env: [String: String] = [:]
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        // Strip surrounding quotes if present.
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        env[key] = value
    }
    return env
}

/// Truthy check for an env-file value. Accepts `true`, `1`, `yes`, `on`
/// (case-insensitive). Anything else (including missing) is false.
public func devEnvFlag(_ env: [String: String], _ key: String) -> Bool {
    guard let raw = env[key]?.lowercased() else { return false }
    return raw == "true" || raw == "1" || raw == "yes" || raw == "on"
}
