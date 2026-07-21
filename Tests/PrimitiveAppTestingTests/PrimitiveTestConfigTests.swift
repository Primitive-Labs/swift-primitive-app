import XCTest
@testable import PrimitiveAppTesting

/// Offline coverage for `PrimitiveTestConfig.fromEnvironment` — the override
/// precedence and the fail-fast on a missing required value. No environment
/// mutation: overrides supply everything so the tests are hermetic.
final class PrimitiveTestConfigTests: XCTestCase {

    func test_overridesSupplyAllRequiredValues() throws {
        let config = try PrimitiveTestConfig.fromEnvironment(overrides: [
            "appId": "app-1",
            "apiUrl": "http://localhost:8787",
            "wsUrl": "ws://localhost:8787",
            "email": "carl+primitivetest-ci@example.com",
        ])
        XCTAssertEqual(config.appId, "app-1")
        XCTAssertEqual(config.apiUrl, "http://localhost:8787")
        XCTAssertEqual(config.wsUrl, "ws://localhost:8787")
        XCTAssertEqual(config.email, "carl+primitivetest-ci@example.com")
        // Defaults.
        XCTAssertEqual(config.otpCode, PrimitiveTestAuth.testOTPCode)
        XCTAssertEqual(config.otpCode, "000000")
    }

    func test_missingRequiredValue_throwsNamingTheEnvVar() {
        // Inject an explicit, empty environment so the missing-`email` path is
        // hermetic: it throws even when the runner's ambient environment
        // happens to set PRIMITIVE_TEST_EMAIL.
        XCTAssertThrowsError(
            try PrimitiveTestConfig.fromEnvironment(
                overrides: [
                    "appId": "app-1",
                    "apiUrl": "http://localhost:8787",
                    "wsUrl": "ws://localhost:8787",
                    // email intentionally absent
                ],
                environment: [:]
            )
        ) { error in
            guard case let PrimitiveTestConfigError.missingEnvironment(key, envVar) = error else {
                return XCTFail("expected missingEnvironment, got \(error)")
            }
            XCTAssertEqual(key, "email")
            XCTAssertEqual(envVar, "PRIMITIVE_TEST_EMAIL")
        }
    }
}
