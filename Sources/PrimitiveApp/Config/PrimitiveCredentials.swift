import Foundation
import os

private let logger = Logger(subsystem: "com.primitivelabs.PrimitiveApp", category: "Config")

/// App configuration loaded from `primitive.json` (tracked in git).
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
            return "No primitive.json found. Create one with your appId and serverUrl."
        }
    }
}

// MARK: - Local dev env file

/// Loads a local `.env.local` file (or any of the caller-supplied search
/// paths) into a `[key: value]` dict. Used for dev-only flags like
/// `USE_CLI_AUTH=true` that should never be committed to git.
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

// MARK: - CLI auth bypass (dev mode)

/// Subset of `~/.primitive/credentials.json` (written by the Primitive CLI's
/// `primitive login`). Loaded by `loadPrimitiveCliCredentials()` and used by
/// `PrimitiveAppState` to bypass the email login UI when the dev-mode
/// `USE_CLI_AUTH` flag is set in `.env.local`.
public struct PrimitiveCliCredentials {
    public let accessToken: String
    public let email: String?
    public let name: String?
}

/// Load CLI credentials from one of two sources, in order of preference:
///
/// 1. **Bundled `dev-credentials.json`** in the app's main bundle. This is
///    how iOS device builds (and any sandboxed Xcode build) get a token —
///    `run-ios.sh` reads `~/.primitive/credentials.json` from your Mac,
///    copies it into `dev-credentials.json` at the project root before
///    building, and the file gets bundled as a resource. The presence of
///    a non-empty bundled file is itself the opt-in signal — gated at
///    *build* time by `USE_CLI_AUTH` in `.env.local`, not at runtime.
///
/// 2. **`~/.primitive/credentials.json`** directly. Only attempted on
///    macOS, only when `USE_CLI_AUTH` is true in the local `.env.local`.
///    This is the path for `./run.sh` (SwiftPM, unsandboxed), where the
///    binary can just read your home dir without any build step.
///
/// Returns `nil` if neither source produces a usable token.
public func loadPrimitiveCliCredentials(searchPaths: [URL] = []) -> PrimitiveCliCredentials? {
    // 1. Bundled file (iOS device, Xcode Mac build).
    if let bundledUrl = Bundle.main.url(forResource: "dev-credentials", withExtension: "json"),
       let creds = readCliCredentialsFile(at: bundledUrl) {
        logger.info("CLI credentials loaded from bundle")
        return creds
    }

    // 2. ~/.primitive/credentials.json (macOS only, gated by .env.local).
    #if os(macOS)
    let env = loadPrimitiveDevEnv(searchPaths: searchPaths)
    if devEnvFlag(env, "USE_CLI_AUTH") {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".primitive/credentials.json")
        if let creds = readCliCredentialsFile(at: path) {
            logger.info("CLI credentials loaded from ~/.primitive/credentials.json")
            return creds
        }
        logger.warning("USE_CLI_AUTH set but ~/.primitive/credentials.json is missing or unreadable — run `primitive login` first")
    }
    #endif

    return nil
}

/// Internal helper. Parses a credentials JSON file (the same shape that
/// `primitive login` writes) and pulls out the access token plus the
/// display fields. Returns nil if the file is missing, malformed, or
/// doesn't contain a non-empty `accessToken` (e.g. the empty `{}`
/// placeholder that ships in the project before the build script runs).
///
/// We deliberately distinguish three failure shapes in the logs so a
/// misconfigured dev environment doesn't look identical to "no creds":
///
/// - file missing → silent (this is the normal pre-build state)
/// - file present but unreadable / not JSON → `warning`
/// - file present and parsed but missing/empty `accessToken` → `debug`
///   (the `{}` placeholder is normal before `run-ios.sh` populates it)
private func readCliCredentialsFile(at url: URL) -> PrimitiveCliCredentials? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return nil }

    guard let data = try? Data(contentsOf: url) else {
        logger.warning("Credentials file at \(url.path) exists but is unreadable")
        return nil
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        logger.warning("Credentials file at \(url.path) is not valid JSON")
        return nil
    }
    guard let token = json["accessToken"] as? String, !token.isEmpty else {
        logger.debug("Credentials file at \(url.path) has no accessToken (placeholder?)")
        return nil
    }
    return PrimitiveCliCredentials(
        accessToken: token,
        email: json["email"] as? String,
        name: json["name"] as? String
    )
}
