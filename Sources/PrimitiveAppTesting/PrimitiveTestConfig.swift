import Foundation
import JsBaoClient

/// Connection + test-account settings for the headless `InspectorTest` runner.
///
/// The Swift analog of the options `registerPrimitiveTests` takes in
/// `packages/primitive-app/src/testing/index.ts`: which backend to hit
/// (`appId` / `apiUrl` / `wsUrl`) and which whitelisted `+primitivetest` account
/// to sign in as (`email` / `otpCode`). The env-var names in
/// ``fromEnvironment(overrides:)`` match the JS adapter's (`VITE_APP_ID`,
/// `VITE_API_URL`, `VITE_WS_URL`, `PRIMITIVE_TEST_EMAIL`) so a Swift CI target
/// reads the same environment a Vue one does.
public struct PrimitiveTestConfig: Sendable {
    /// App ID the test account belongs to.
    public var appId: String
    /// HTTP API endpoint, e.g. `http://localhost:8787`.
    public var apiUrl: String
    /// WebSocket endpoint, e.g. `ws://localhost:8787`.
    public var wsUrl: String
    /// Sign-in email for the OTP test bypass. Must resolve to the app's
    /// `testAccountBaseEmails` whitelist — a `<base-local>+primitivetest<suffix>@<domain>`
    /// derivative of a whitelisted base (see `src/auth/test-email.ts`). Use a
    /// stable suffix per CI target so the find-or-create provisioner reuses one
    /// test user across runs.
    public var email: String
    /// OTP code to verify with. Defaults to the `"000000"` test bypass.
    public var otpCode: String
    /// How long to wait for auth to settle after `otpVerify`, in seconds.
    public var authTimeout: TimeInterval
    /// Client storage backend. Defaults to in-memory so CI needs no on-disk
    /// SQLite file and runs are isolated from each other.
    public var storageConfig: StorageConfig
    /// Global-admin app ID. `nil` uses the client default (`global-admin-app`).
    /// Set it when the app was created under a non-default global-admin context.
    public var globalAdminAppId: String?
    /// Extra headers sent on the WebSocket upgrade. A local dev server needs
    /// `X-Global-Admin-App-Id` here so the WS upgrade resolves the admin
    /// context (mirrors the JS README recipe's `wsHeaders`); a deployed server
    /// uses its env default and needs none.
    public var wsHeaders: [String: String]

    public init(
        appId: String,
        apiUrl: String,
        wsUrl: String,
        email: String,
        otpCode: String = PrimitiveTestAuth.testOTPCode,
        authTimeout: TimeInterval = 15,
        storageConfig: StorageConfig = .memory,
        globalAdminAppId: String? = nil,
        wsHeaders: [String: String] = [:]
    ) {
        self.appId = appId
        self.apiUrl = apiUrl
        self.wsUrl = wsUrl
        self.email = email
        self.otpCode = otpCode
        self.authTimeout = authTimeout
        self.storageConfig = storageConfig
        self.globalAdminAppId = globalAdminAppId
        self.wsHeaders = wsHeaders
    }

    /// Build a config from the process environment, mirroring the JS adapter's
    /// env-var names. Throws ``PrimitiveTestConfigError/missingEnvironment`` with
    /// the missing variable named — the same fail-fast contract
    /// `registerPrimitiveTests` gives when a required option is absent.
    ///
    /// - `appId`   ← `VITE_APP_ID`
    /// - `apiUrl`  ← `VITE_API_URL`
    /// - `wsUrl`   ← `VITE_WS_URL`
    /// - `email`   ← `PRIMITIVE_TEST_EMAIL`
    ///
    /// Pass `overrides` to supply any of these in code (an override wins over
    /// the environment) — handy for tests that provision their own app. Pass
    /// `environment` to read from an explicit dictionary instead of the process
    /// environment — used by tests to make the missing-value path hermetic
    /// regardless of the runner's ambient environment.
    public static func fromEnvironment(
        overrides: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        otpCode: String = PrimitiveTestAuth.testOTPCode,
        authTimeout: TimeInterval = 15,
        storageConfig: StorageConfig = .memory
    ) throws -> PrimitiveTestConfig {
        func required(_ key: String, _ envVar: String) throws -> String {
            if let v = overrides[key], !v.isEmpty { return v }
            if let v = environment[envVar], !v.isEmpty { return v }
            throw PrimitiveTestConfigError.missingEnvironment(key: key, envVar: envVar)
        }
        return PrimitiveTestConfig(
            appId: try required("appId", "VITE_APP_ID"),
            apiUrl: try required("apiUrl", "VITE_API_URL"),
            wsUrl: try required("wsUrl", "VITE_WS_URL"),
            email: try required("email", "PRIMITIVE_TEST_EMAIL"),
            otpCode: otpCode,
            authTimeout: authTimeout,
            storageConfig: storageConfig
        )
    }
}

/// Raised when a required ``PrimitiveTestConfig`` value is absent from both the
/// overrides and the process environment.
public enum PrimitiveTestConfigError: Error, CustomStringConvertible {
    case missingEnvironment(key: String, envVar: String)

    public var description: String {
        switch self {
        case let .missingEnvironment(key, envVar):
            return "[PrimitiveAppTesting] Missing \(key): pass it in overrides or set the \(envVar) environment variable."
        }
    }
}
