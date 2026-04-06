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
