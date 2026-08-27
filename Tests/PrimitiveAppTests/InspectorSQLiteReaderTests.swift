#if DEBUG
import XCTest
import SQLite3
@testable import PrimitiveApp

/// #2476 — the debug inspector's storage panel reported `path: null` against a
/// healthy database because `InspectorSQLiteReader` only matched the pre-#853
/// namespace layout (`<appId>:<userId>` directories). Since #853 the client
/// writes to a bare `JsBaoClient/<appId>/jsbao_storage.sqlite`, which the old
/// `hasPrefix("\(appId):")` filter rejected.
///
/// These tests drive the reader against temporary roots so both layouts — and
/// the directory names that must NOT match — are checked without an app running.
final class InspectorSQLiteReaderTests: XCTestCase {

    private var root: String = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = NSTemporaryDirectory() + "InspectorSQLiteReaderTests-\(UUID().uuidString)/JsBaoClient"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let container = (root as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: container)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Creates `<root>/<dir>/jsbao_storage.sqlite` (optionally without the file)
    /// and stamps its modification date so mtime ordering is deterministic.
    @discardableResult
    private func makeNamespaceDir(
        _ dir: String,
        withDatabase: Bool = true,
        stores: [String: Int] = [:],
        mtime: Date = Date()
    ) throws -> String {
        let path = (root as NSString).appendingPathComponent(dir)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let dbPath = (path as NSString).appendingPathComponent("jsbao_storage.sqlite")
        if withDatabase {
            try writeDatabase(at: dbPath, stores: stores)
        }
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        return dbPath
    }

    /// Writes a minimal `kv_store` database matching the client's schema.
    private func writeDatabase(at path: String, stores: [String: Int]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw XCTSkip("could not create test sqlite file at \(path)")
        }
        defer { sqlite3_close_v2(db) }
        let schema = """
            CREATE TABLE IF NOT EXISTS kv_store (
                store TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT,
                metadata TEXT,
                updated_at TEXT,
                PRIMARY KEY (store, key)
            )
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for (store, count) in stores {
            for i in 0..<count {
                let sql = """
                    INSERT INTO kv_store (store, key, value, metadata, updated_at)
                    VALUES ('\(store)', 'k\(i)', 'v\(i)', NULL, '2026-08-05T00:00:0\(i)Z')
                    """
                XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            }
        }
    }

    private func reader(appId: String) -> InspectorSQLiteReader {
        InspectorSQLiteReader(appId: appId, rootsOverride: [root])
    }

    // MARK: - Behavior 1: the current (post-#853) bare-appId layout resolves

    func testResolvesBareAppIdDirectory() throws {
        let expected = try makeNamespaceDir("app123", stores: ["documents": 2])
        let reader = self.reader(appId: "app123")

        XCTAssertEqual(reader.resolveDatabasePath(), expected)
        let stores = reader.listStores()
        XCTAssertEqual(stores.map(\.name), ["documents"])
        XCTAssertEqual(stores.first?.rowCount, 2)
    }

    /// The diagnostic payload behind `/api/sqlite/diag` must show the matched
    /// directory too — a dev reading it should not see "no matching namespace dir".
    func testDiagnosticReportsBareAppIdDirectory() throws {
        try makeNamespaceDir("app123")
        let diag = reader(appId: "app123").resolve()

        XCTAssertNotNil(diag.path)
        XCTAssertEqual(diag.candidateRoots, [root])
        XCTAssertEqual(diag.candidates.first?.subdirs.map(\.name), ["app123"])
    }

    // MARK: - Behavior 2: the legacy `<appId>:<userId>` layout still resolves

    func testResolvesLegacyNamespacedDirectory() throws {
        let expected = try makeNamespaceDir("app123:user789", stores: ["documents": 1])
        XCTAssertEqual(reader(appId: "app123").resolveDatabasePath(), expected)
    }

    // MARK: - Behavior 3: newest directory holding a database wins

    func testPrefersNewestMatchingDirectory() throws {
        try makeNamespaceDir("app123:user789", mtime: Date(timeIntervalSince1970: 1_000))
        let newest = try makeNamespaceDir("app123", mtime: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(reader(appId: "app123").resolveDatabasePath(), newest)
    }

    /// Edge case: the newest matching directory exists but has no database file
    /// yet. Falling back to the next-newest keeps a real database visible
    /// instead of reporting `path: null`.
    func testFallsBackWhenNewestDirectoryHasNoDatabaseFile() throws {
        let older = try makeNamespaceDir("app123:user789", mtime: Date(timeIntervalSince1970: 1_000))
        try makeNamespaceDir("app123", withDatabase: false, mtime: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(reader(appId: "app123").resolveDatabasePath(), older)
    }

    // MARK: - Behavior 4 + edge cases: what must not match

    func testIgnoresAuthAndUnrelatedDirectories() throws {
        try makeNamespaceDir("auth:app123:user789")
        try makeNamespaceDir("app123-other")
        try makeNamespaceDir("app1234")
        try makeNamespaceDir("otherapp")

        let diag = reader(appId: "app123").resolve()
        XCTAssertEqual(diag.candidates.first?.subdirs.map(\.name), [])
        XCTAssertNil(diag.path)
    }

    func testNoMatchingDirectoryStillReportsRoots() {
        let diag = reader(appId: "app123").resolve()
        XCTAssertNil(diag.path)
        XCTAssertEqual(diag.candidateRoots, [root])
    }
}
#endif
