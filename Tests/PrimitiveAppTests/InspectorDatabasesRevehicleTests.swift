import XCTest

/// The debug inspector's database controls ride the admin-only `databases`
/// routes (#3189, server-functions phase 6).
///
/// The Swift client no longer carries `client.databases`, so the inspector's
/// `db/create|rename|delete` actions and its database list and model-describe
/// reads post the `databases` routes through `client.requestJSON` — the
/// shape #3188 gave its operation controls. Those routes answer only an app
/// admin or owner; a member running the inspector gets the server's 403 back
/// as the action's displayed error. Database operations retired with the
/// concept, so the registered-operation controls and their UI are gone.
///
/// The wiring is only visible in the source (standing up the inspector's HTTP
/// server needs a running app), so it is checked there — the
/// `InspectorEventRecordTests` shape.
final class InspectorDatabasesRevehicleTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        // .../Tests/PrimitiveAppTests/<this file>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent(relative), encoding: .utf8)
    }

    private var inspector: String {
        get throws { try source("Sources/PrimitiveApp/Debug/DebugInspector.swift") }
    }

    func testTheInspectorCallsNoClientDatabasesMember() throws {
        let code = try inspector
        XCTAssertFalse(code.contains("client.databases"), "client.databases retired (#3189)")
        for retired in ["CreateDatabaseParams", "UpdateDatabaseParams", "DatabaseOperationInfo"] {
            XCTAssertFalse(code.contains(retired), "\(retired) left with client.databases")
        }
        let mapping = try source("Sources/PrimitiveApp/Debug/InspectorTypeMapping.swift")
        for retired in ["extension DatabaseInfo", "extension DatabaseOperationInfo", "extension ModelFieldInfo"] {
            XCTAssertFalse(mapping.contains(retired), "\(retired) left with client.databases")
        }
    }

    func testTheDatabaseActionsPostTheAdminOnlyRoutes() throws {
        let code = try inspector
        // create, rename, delete and the list ride `requestJSON` on the
        // `databases` routes; describe reads the records route.
        XCTAssertTrue(code.contains(#"method: .post, path: "/databases""#), "db/create posts POST /databases")
        XCTAssertTrue(code.contains(#"method: .patch, path: "/databases/\(id)""#), "db/rename patches the database")
        XCTAssertTrue(code.contains(#"method: .delete, path: "/databases/\(id)""#), "db/delete deletes the database")
        XCTAssertTrue(code.contains(#"method: .get, path: "/databases""#), "the list reads GET /databases")
        XCTAssertTrue(code.contains("/records/describe"), "describe reads the records route")
    }

    func testTheOperationControlsAreGone() throws {
        let code = try inspector
        for retired in ["\"db/execute\"", "\"/api/db/operations\"", "/operations"] {
            XCTAssertFalse(code.contains(retired), "\(retired) retired with database operations")
        }
        for tab in ["Sources/PrimitiveApp/Debug/ui/tabs/databases.js",
                    "Sources/PrimitiveApp/Debug/ui/tabs/databases.html"] {
            let ui = try source(tab)
            for retired in ["/api/db/operations", "db/execute", "dbOperations", "runOperation"] {
                XCTAssertFalse(ui.contains(retired), "\(tab) still carries \(retired)")
            }
        }
    }
}
