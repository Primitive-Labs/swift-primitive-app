import XCTest
@testable import PrimitiveApp
@testable import PrimitiveAppTesting
import JsBaoClient

/// #4140 — `fetchDocuments()` lists every owned and shared document, not just
/// the first page of each, against the live server through the real client.
///
/// `GET /me/owned-documents` and `GET /me/shared-documents` cap the queries one
/// request may run, so a page can come back short or empty with
/// `hasMore: true` while later pages still hold documents. The fixture puts
/// such a page in front of later documents in both lists at a page size of
/// one: the holder owns one document, then is shared eleven, then owns eleven
/// more. The shared list's first page meets only the eleven newest owner rows;
/// the owned list meets the eleven shares before its oldest document.
///
/// No mocks (repo rule) — this hits the local dev server on :8787. It skips
/// cleanly when no server is reachable rather than failing the suite.
@MainActor
final class PrimitiveAppStateFetchDocumentsPagingLiveTests: XCTestCase {

    private var appId: String?
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        let reachable = await LiveBackend.isReachable()
        try XCTSkipUnless(
            reachable,
            "Dev server not reachable at \(LiveBackend.httpUrl) — start `node debug-server.js`."
        )
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        if let appId { await LiveBackend.deleteApp(appId) }
        appId = nil
    }

    private struct Page: Decodable, Sendable {
        struct Row: Decodable, Sendable { let documentId: String }
        let items: [Row]
        let hasMore: Bool
        let nextCursor: String?
    }

    private func signIn(_ app: LiveBackend.WhitelistedApp, as suffix: String) async throws -> JsBaoClient {
        let email = app.baseEmail.replacingOccurrences(of: "@", with: "+primitivetest-\(suffix)@")
        let client = try await PrimitiveTestAuth.bootstrapClient(config: PrimitiveTestConfig(
            appId: app.appId,
            apiUrl: LiveBackend.httpUrl,
            wsUrl: LiveBackend.wsUrl,
            email: email,
            globalAdminAppId: LiveBackend.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": LiveBackend.globalAdminAppId]
        ))
        clients.append(client)
        return client
    }

    /// A document committed on the server before this returns, so the
    /// fixture's permission rows land in order.
    private func createDocument(_ client: JsBaoClient, _ title: String) async throws -> String {
        let created = try await client.requestJSON(method: .post, path: "/documents", body: ["title": title])
        return try XCTUnwrap(created?["documentId"]?.stringValue, "POST /documents returned no documentId")
    }

    /// Every page of a `me` list over REST, as the server answers it.
    private func restPages(_ client: JsBaoClient, _ path: String) async throws -> [Page] {
        var pages: [Page] = []
        var cursor: String?
        for _ in 0..<100 {
            let url = cursor.map {
                "\(path)&cursor=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)"
            } ?? path
            let page: Page = try await client.request(method: .get, path: url)
            pages.append(page)
            guard page.hasMore, let next = page.nextCursor else { break }
            cursor = next
        }
        return pages
    }

    func testFetchDocumentsReachesEveryDocumentPastEmptyPages() async throws {
        let app = try await LiveBackend.createWhitelistedApp()
        appId = app.appId
        let holder = try await signIn(app, as: "holder")
        let sharer = try await signIn(app, as: "sharer")
        let holderId = try XCTUnwrap(holder.userId)

        var owned = [try await createDocument(holder, "owned-oldest")]
        var shared: [String] = []
        for i in 0..<11 {
            let id = try await createDocument(sharer, "shared-\(i)")
            _ = try await sharer.documents.updatePermissions(
                documentId: id,
                params: UpdatePermissionsData(userId: holderId, permission: "reader")
            )
            shared.append(id)
        }
        for i in 0..<11 { owned.append(try await createDocument(holder, "owned-\(i)")) }

        // Wait out the user index's propagation before reading it.
        let deadline = Date().addingTimeInterval(30)
        while true {
            let ownedNow = try await restPages(holder, "/me/owned-documents?limit=100").flatMap(\.items)
            let sharedNow = try await restPages(holder, "/me/shared-documents?limit=100").flatMap(\.items)
            if ownedNow.count == owned.count && sharedNow.count == shared.count { break }
            if Date() > deadline { return XCTFail("the user index never caught up with the fixture") }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // The server answers an empty page with hasMore: true in front of
        // later documents in both lists.
        let sharedPages = try await restPages(holder, "/me/shared-documents?limit=1")
        XCTAssertEqual(sharedPages.first?.items.count, 0)
        XCTAssertEqual(sharedPages.first?.hasMore, true)
        let ownedPages = try await restPages(holder, "/me/owned-documents?limit=1")
        let emptyAt = ownedPages.firstIndex { $0.items.isEmpty && $0.hasMore }
        let oldestAt = ownedPages.firstIndex { $0.items.contains { $0.documentId == owned[0] } }
        XCTAssertNotNil(emptyAt)
        XCTAssertGreaterThan(oldestAt ?? -1, emptyAt ?? Int.max)

        // fetchDocuments() follows hasMore past them, reading every page the
        // server serves. The page reads are counted because rows alone cannot
        // show it: the client merges its warm local metadata cache into
        // `me.sharedDocuments` pages and into the owned list.
        let (source, reads) = Self.counted(.client(holder, pageSize: 1))
        let state = PrimitiveAppState()
        await state.fetchDocuments(from: source)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(reads.counts.owned, ownedPages.count)
        XCTAssertEqual(reads.counts.shared, sharedPages.count)
        let listed = Dictionary(
            state.documents.map { ($0.id, $0.permission) }, uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(listed.count, state.documents.count, "a document is listed twice")
        for id in owned { XCTAssertEqual(listed[id], "owner", "owned \(id)") }
        for id in shared { XCTAssertEqual(listed[id], "reader", "shared \(id)") }

        // The walk stops at its page cap and says so.
        let (capped, cappedReads) = Self.counted(.client(holder, pageSize: 1, pageCap: 2))
        let lists = try await capped.readAll()
        XCTAssertFalse(lists.complete)
        XCTAssertEqual(cappedReads.counts.owned, 2)
        XCTAssertEqual(cappedReads.counts.shared, 2)
    }

    /// `source`, counting the server page reads it makes.
    private static func counted(_ source: DocumentListSource) -> (DocumentListSource, Reads) {
        let reads = Reads()
        var counted = source
        let ownedPage = source.ownedPage
        let sharedPage = source.sharedPage
        counted.ownedPage = { cursor in
            reads.owned()
            return try await ownedPage(cursor)
        }
        counted.sharedPage = { cursor in
            reads.shared()
            return try await sharedPage(cursor)
        }
        return (counted, reads)
    }

    /// Counts the page reads a source makes.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var ownedReads = 0
        private var sharedReads = 0
        func owned() { lock.withLock { ownedReads += 1 } }
        func shared() { lock.withLock { sharedReads += 1 } }
        var counts: (owned: Int, shared: Int) { lock.withLock { (ownedReads, sharedReads) } }
    }
}
