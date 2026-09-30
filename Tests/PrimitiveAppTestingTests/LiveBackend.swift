import Foundation
import CryptoKit

/// Minimal live-server provisioning for the OTP-bootstrap integration test.
///
/// Replicates the pieces of `swift-client`'s `TestConfig` / `TestContext` this
/// package needs — resolving a super-admin JWT for a real admin row and
/// creating a whitelisted test app via the admin REST API — without depending
/// on that (test-only) target. Mirrors the JS parallel in
/// `tests/client/js-bao-client-node-otp-bootstrap.test.ts`: the app is created
/// in the server's canonical global-admin context (`global-admin-app`) so the
/// pre-auth, header-less OTP verify resolves it, with email sign-in on and the
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
        case setup(String)

        var description: String {
            switch self {
            case let .serverUnreachable(m): return "dev server unreachable: \(m)"
            case let .http(code, body): return "HTTP \(code): \(body)"
            case let .badResponse(m): return "bad response: \(m)"
            case let .setup(m): return m
            }
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    /// The local test routes' `X-Test-Auth` secret.
    static let testAdminToken = ProcessInfo.processInfo.environment["TEST_ADMIN_TOKEN"] ?? "local-test-secret"

    /// The route a local dev server provisions a harness admin through (#3885).
    static let ensureSuperAdminRoute = "/__test__/admin/ensure-super-admin"

    /// The admin this package's live tests provision when no variable names one.
    static let harnessAdminEmail = "swift-primitive-app-tests@js-bao-wss.test"

    /// The super-admin the tests act as: its token and email.
    private struct AdminIdentity: Sendable {
        let jwt: String
        let email: String
    }

    private static let identityTask = Task<AdminIdentity, Error> {
        try await resolveIdentity(environment: ProcessInfo.processInfo.environment)
    }

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

    /// Create a public app in the global-admin context with `emailSignInEnabled` and the
    /// base email whitelisted. Returns the ids needed to bootstrap a client.
    static func createWhitelistedApp() async throws -> WhitelistedApp {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let baseEmail = "swift-otp-\(ts)@example.com"
        let signInEmail = "swift-otp-\(ts)+primitivetest-ci@example.com"

        let createBody: [String: Any] = [
            "name": "PrimitiveAppTesting otp bootstrap \(ts)",
            "mode": "public",
            "initialAdminEmail": try await identityTask.value.email,
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
            _ = try await admin("PUT", "/admin/api/apps/\(appId)", body: ["emailSignInEnabled": true])
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
        request.setValue("Bearer \(try await identityTask.value.jwt)", forHTTPHeaderField: "Authorization")
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

    // MARK: - Super-admin identity, mirroring swift-client TestConfig (#3885).

    /// The tests' super-admin, in order: `TEST_SUPERADMIN_JWT`; an email-only
    /// token for `TEST_SUPERADMIN_EMAIL`; otherwise the local server's
    /// test-only `ensureSuperAdminRoute` finds or creates `harnessAdminEmail`
    /// and the token names that row. The server refuses a token whose
    /// `adminId` has no row, so the tests can no longer invent one.
    private static func resolveIdentity(environment: [String: String]) async throws -> AdminIdentity {
        if let jwt = environment["TEST_SUPERADMIN_JWT"], !jwt.isEmpty {
            return AdminIdentity(jwt: jwt, email: emailClaim(of: jwt) ?? "")
        }
        if let email = environment["TEST_SUPERADMIN_EMAIL"], !email.isEmpty {
            return AdminIdentity(jwt: signSuperAdminJwt(adminId: nil, email: email), email: email)
        }
        do {
            let (adminId, email) = try await provisionHarnessAdmin()
            return AdminIdentity(jwt: signSuperAdminJwt(adminId: adminId, email: email), email: email)
        } catch {
            throw LiveError.setup(
                "No super-admin for the live tests: POST \(ensureSuperAdminRoute) on \(httpUrl) "
                + "failed (\(error)). Run against a local dev server (USE_TEST_ROUTES=true, "
                + "ENVIRONMENT local or test) with TEST_ADMIN_TOKEN matching its test token, "
                + "or set TEST_SUPERADMIN_JWT to a super-admin token, or TEST_SUPERADMIN_EMAIL "
                + "to an existing admin's email."
            )
        }
    }

    private static func provisionHarnessAdmin() async throws -> (String, String) {
        guard let url = URL(string: "\(httpUrl)\(ensureSuperAdminRoute)") else {
            throw LiveError.badResponse("bad url \(ensureSuperAdminRoute)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(testAdminToken, forHTTPHeaderField: "X-Test-Auth")
        request.setValue(globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["email": harnessAdminEmail, "name": "Swift PrimitiveApp Test Admin"]
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveError.serverUnreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LiveError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let adminId = json["adminId"] as? String,
            let email = json["email"] as? String
        else {
            throw LiveError.badResponse("no adminId in \(String(data: data, encoding: .utf8) ?? "")")
        }
        return (adminId, email)
    }

    private static func emailClaim(of jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["email"] as? String
    }

    /// An HS256 super-admin JWT for an existing row (`adminId`), or an
    /// email-only one (`adminId` nil) the server resolves by `email`.
    private static func signSuperAdminJwt(adminId: String?, email: String) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        var payload: [String: Any] = [
            "email": email,
            "name": "Swift PrimitiveApp Test Admin",
            "role": "super-admin",
            "isSuperAdmin": true,
            "appCreationLimit": 50,
            "type": "admin",
            "enableTestFeatures": true,
            "iat": now,
            "exp": now + 3600,
        ]
        if let adminId { payload["adminId"] = adminId }
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
