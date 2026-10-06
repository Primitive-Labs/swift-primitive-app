import Foundation
import JsBaoClient

/// The document-list reads `PrimitiveAppState.fetchDocuments()` makes: one
/// page of the caller's owned or shared documents at a time, plus the owned
/// rows only the local cache holds.
struct DocumentListSource: Sendable {
    /// Rows requested per page: the server's cap for both lists.
    static let pageSize = 100
    /// Pages read per list before stopping (5,000 rows at `pageSize`), so a
    /// listing never walks an unbounded history.
    static let maxPages = 50

    /// One page of the caller's owned documents, from `cursor` (nil: the first).
    var ownedPage: @Sendable (_ cursor: String?) async throws -> DocumentListPage
    /// The owned rows the local cache holds.
    var localOwned: @Sendable () async throws -> [DocumentInfo]
    /// One page of the documents shared with the caller, from `cursor`.
    var sharedPage: @Sendable (_ cursor: String?) async throws -> SharedDocumentListResult
    /// Pages `readAll()` reads per list before stopping.
    var pageCap: Int = DocumentListSource.maxPages

    /// The source backed by `client.me`, reading `pageSize` rows per page and
    /// at most `pageCap` pages per list.
    static func client(
        _ client: JsBaoClient,
        pageSize: Int = DocumentListSource.pageSize,
        pageCap: Int = DocumentListSource.maxPages
    ) -> DocumentListSource {
        DocumentListSource(
            ownedPage: { cursor in
                try await client.me.ownedDocumentsPage(cursor: cursor, limit: pageSize)
            },
            localOwned: {
                try await client.me.ownedDocuments(
                    options: MeOwnedDocumentsOptions(localOnly: true)
                )
            },
            sharedPage: { cursor in
                try await client.me.sharedDocuments(cursor: cursor, limit: pageSize)
            },
            pageCap: pageCap
        )
    }

    /// Every owned and shared document, each list deduped by `documentId`.
    struct Lists: Sendable {
        /// Owned rows from every server page, then the cached owned rows the
        /// pages did not carry (a document created a moment ago).
        var owned: [DocumentInfo]
        var shared: [SharedDocument]
        /// False when either list stopped at `pageCap`.
        var complete: Bool
    }

    /// Read both lists, following `nextCursor` while `hasMore` is true. A page
    /// may be short or empty and still have more behind it, so the walk never
    /// stops on an empty page.
    func readAll() async throws -> Lists {
        async let ownedTask = Self.readPages(cap: pageCap) { cursor in
            let page = try await ownedPage(cursor)
            return (page.items, page.hasMore, page.nextCursor)
        }
        async let localTask = localOwned()
        async let sharedTask = Self.readPages(cap: pageCap) { cursor in
            let page = try await sharedPage(cursor)
            return (page.items, page.hasMore, page.nextCursor)
        }
        let (owned, ownedComplete) = try await ownedTask
        let local = try await localTask
        let (shared, sharedComplete) = try await sharedTask
        return Lists(
            owned: Self.uniqued(owned + local, id: \.documentId),
            shared: Self.uniqued(shared, id: \.document.documentId),
            complete: ownedComplete && sharedComplete
        )
    }

    private static func readPages<Row: Sendable>(
        cap: Int,
        _ fetch: @Sendable (_ cursor: String?) async throws
            -> (items: [Row], hasMore: Bool, nextCursor: String?)
    ) async throws -> (rows: [Row], complete: Bool) {
        var rows: [Row] = []
        var cursor: String?
        for _ in 0..<cap {
            let page = try await fetch(cursor)
            rows.append(contentsOf: page.items)
            guard page.hasMore, let next = page.nextCursor else { return (rows, true) }
            cursor = next
        }
        return (rows, false)
    }

    private static func uniqued<Row>(_ rows: [Row], id: KeyPath<Row, String>) -> [Row] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0[keyPath: id]).inserted }
    }
}
