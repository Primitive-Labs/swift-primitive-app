import Foundation
import CryptoKit

/// Minimal live-server provisioning for the OTP-bootstrap integration test.
///
/// Replicates the pieces of `swift-client`'s `TestConfig` / `TestContext` this
/// package needs — self-minting a super-admin JWT and creating a whitelisted
/// test app via the admin REST API — without depending on that (test-only)
/// target. Mirrors the JS parallel in
/// `tests/client/js-bao-client-node-otp-bootstrap.test.ts`: the app is created
/// in the server's canonical global-admin context (`global-admin-app`) so the
/// pre-auth, header-less OTP verify resolves it, with `otpEnabled` on and the
/// base email whitelisted for the `+primitivetest` bypass.
enum LiveBackend {

    static let httpUrl = ProcessInfo.processInfo.environment["TEST_HTTP_URL"] ?? "http://localhost:8787"
    static let wsUrl = ProcessInfo.processInfo.environment["TEST_WS_URL"] ?? "ws://localhost:8787"
    static let jwtSecret = ProcessInfo.processInfo.environment["TEST_JWT_SECRET"] ?? "test-jwt-secret-only-for-agents"
    static let globalAdminAppId = ProcessInfo.processInfo.environment["TEST_GLOBAL_ADMIN_APP_ID"] ?? "global-admin-app"

    struct WhitelistedApp {
        let appId: String
        /// Whitelisted base email (never itself a test account).
        let baseEmail: String
        /// `<base-local>+primitivetest-ci@<domain>` — the account to sign in as.
        let signInEmail: String
    }

    enum LiveError: Error, CustomStringConvertible {
        case serverUnreachable(String)
        case http(Int, String)
        case badResponse(String)

        var description: String {
            switch self {
            case let .serverUnreachable(m): return "dev server unreachable: \(m)"
            case let .http(code, body): return "HTTP \(code): \(body)"
            case let .badResponse(m): return "bad response: \(m)"
            }
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    private static let adminEmail = "swift-primitiveapp-\(UUID().uuidString.prefix(8))@example.com"

    /// True when the dev server answers on `httpUrl`. Lets a test `XCTSkip`
    /// cleanly instead of failing when no server is running.
    static func isReachable() async -> Bool {
        guard let url = URL(string: httpUrl) else { return false }
        do {
            let (_, response) = try await session.data(for: URLRequest(url: url))
            return (response as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }

    /// Create a public app in the global-admin context with `otpEnabled` and the
    /// base email whitelisted. Returns the ids needed to bootstrap a client.
    static func createWhitelistedApp() async throws -> WhitelistedApp {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let baseEmail = "swift-otp-\(ts)@example.com"
        let signInEmail = "swift-otp-\(ts)+primitivetest-ci@example.com"

        let createBody: [String: Any] = [
            "name": "PrimitiveAppTesting otp bootstrap \(ts)",
            "mode": "public",
            "initialAdminEmail": adminEmail,
            "description": "PrimitiveAppTesting live OTP bootstrap",
            "testAccountBaseEmails": [baseEmail],
        ]
        let created = try await admin("POST", "/admin/api/apps", body: createBody)
        guard let appId = created["appId"] as? String else {
            throw LiveError.badResponse("missing appId in \(created)")
        }
        // The app now exists. If any post-create setup fails, delete it before
        // rethrowing so the orphan can't leak (the caller only records the appId
        // on success, so tearDown never sees it otherwise) — but rethrow the
        // original error so the test still fails for the real reason.
        do {
            // Enable OTP (the create path doesn't take it; mirror the JS test's app config).
            _ = try await admin("PUT", "/admin/api/apps/\(appId)", body: ["otpEnabled": true])
            return WhitelistedApp(appId: appId, baseEmail: baseEmail, signInEmail: signInEmail)
        } catch {
            await deleteApp(appId)
            throw error
        }
    }

    static func deleteApp(_ appId: String) async {
        _ = try? await admin("DELETE", "/admin/api/apps/\(appId)", body: nil)
    }

    // MARK: - Admin HTTP

    @discardableResult
    private static func admin(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        guard let url = URL(string: "\(httpUrl)\(path)") else {
            throw LiveError.badResponse("bad url \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(superAdminJwt())", forHTTPHeaderField: "Authorization")
        request.setValue(globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveError.serverUnreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LiveError.badResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LiveError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Self-minted super-admin JWT (HS256), mirroring swift-client TestConfig.

    private static func superAdminJwt() -> String {
        if let jwt = ProcessInfo.processInfo.environment["TEST_SUPERADMIN_JWT"], !jwt.isEmpty {
            return jwt
        }
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "adminId": "swift-primitiveapp-\(UUID().uuidString.prefix(8))",
            "email": adminEmail,
            "name": "Swift PrimitiveApp Test Admin",
            "role": "super-admin",
            "isSuperAdmin": true,
            "appCreationLimit": 50,
            "type": "admin",
            "enableTestFeatures": true,
            "iat": now,
            "exp": now + 3600,
        ]
        let headerData = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data()
        let payloadData = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let signingInput = base64url(headerData) + "." + base64url(payloadData)
        let key = SymmetricKey(data: Data(jwtSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        return signingInput + "." + base64url(Data(mac))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
