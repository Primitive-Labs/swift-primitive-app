import Foundation
import JsBaoClient

// MARK: - Typed read summaries
//
// The `JsBaoClient` read APIs now return typed `Decodable` structs
// (`DocumentInfo`, `SharedDocumentListResult`, `CollectionInfo`, …) directly,
// so most of the app-side typed wrappers that used to re-shape raw
// `[String: Any]` responses are redundant — call the client's typed methods
// instead.
//
// What stays here is the app-level value-add that the client doesn't provide
// 1:1:
//   - `accessibleDocumentSummaries`: merges `ownedDocuments` + `sharedDocuments`
//     into one de-duped list with an `origin` discriminator (the former
//     `me.accessibleDocuments` client helper, removed to keep the Swift client
//     1:1 with JS).
//   - the typed `getOrCreateWithAlias(alias:)` overload: takes the app's typed
//     ``DocumentAlias`` and returns a typed ``AliasedDocument``.

// MARK: Decoding support

/// Decodes a `Decodable` value from an already-parsed JSON object
/// (`[String: Any]` / `[[String: Any]]`). Round-trips through
/// `JSONSerialization` so a small amount of dict-shaping (e.g. merging two
/// typed lists) can still hydrate the app's `Decodable` summary structs.
private let summaryDecoder = JSONDecoder()

private func decodeSummary<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try summaryDecoder.decode(T.self, from: data)
}

// MARK: - DocumentSummary

/// One row from ``MeAPI/accessibleDocumentSummaries(tag:limit:)`` — the merged
/// owned + shared view of every document the caller can read or write.
///
/// `permission` is always present (`"owner"` for owned docs), so it's
/// non-optional. `origin` (`"owned"` / `"shared"`) is injected by the merge.
/// The slim shared-document rows omit `createdBy` / `createdAt` /
/// `lastModified`, hence those are optional.
public struct DocumentSummary: Decodable, Sendable, Identifiable, Hashable {
    public let documentId: String
    public let title: String
    public let permission: String
    public let createdBy: String?
    public let createdAt: String?
    public let lastModified: String?

    /// `"owned"` / `"shared"` — set by the merge.
    public let origin: String?
    public let grantedAt: String?
    public let tags: [String]?
    public let thumbnailBlobId: String?

    public var id: String { documentId }

    /// `true` when the current user owns the document.
    public var isOwned: Bool { origin == "owned" || permission == "owner" }

    private enum CodingKeys: String, CodingKey {
        case documentId, title, permission, createdBy, createdAt, lastModified
        case origin = "_origin"
        case grantedAt, tags, thumbnailBlobId
    }
}

// MARK: - Paginated-list container

/// `{ "items": [...] }` envelope used to hydrate `[Element]` from a hand-built
/// merged dict.
private struct ItemsEnvelope<Element: Decodable>: Decodable {
    let items: [Element]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([Element].self, forKey: .items) ?? []
    }
    private enum CodingKeys: String, CodingKey { case items }
}

// MARK: - Typed wrappers: MeAPI

extension MeAPI {
    /// Typed, merged "every doc I can read or write" view — the app-level
    /// replacement for the former `me.accessibleDocuments` client helper.
    /// That helper was removed to keep the Swift client 1:1 with the JS
    /// client, which exposes only `ownedDocuments` / `sharedDocuments`.
    /// We fetch both sides, de-dupe by `documentId` (owned wins on overlap),
    /// and inject the `_origin` discriminator (`"owned"` / `"shared"`) that
    /// ``DocumentSummary/origin`` decodes.
    public func accessibleDocumentSummaries(
        tag: String? = nil,
        limit: Int? = nil
    ) async throws -> [DocumentSummary] {
        async let ownedTask = ownedDocuments(limit: limit, tag: tag)
        async let sharedTask = sharedDocuments(limit: limit, tag: tag)
        let owned = try await ownedTask        // [DocumentInfo]
        let shared = try await sharedTask      // SharedDocumentListResult

        var merged: [[String: Any]] = []
        var seen = Set<String>()
        func append(_ info: DocumentInfo, origin: String) {
            let id = info.documentId
            guard !id.isEmpty, seen.insert(id).inserted else { return }
            var row: [String: Any] = [
                "documentId": id,
                "title": info.title,
                "permission": info.permission.rawValue,
                "createdBy": info.createdBy,
                "createdAt": info.createdAt,
                "lastModified": info.lastModified,
                "_origin": origin,
            ]
            if let tags = info.tags { row["tags"] = tags }
            if let thumb = info.thumbnailBlobId { row["thumbnailBlobId"] = thumb }
            if let grantedAt = info.grantedAt { row["grantedAt"] = grantedAt }
            merged.append(row)
        }
        // Owned appended first so it wins for any doc present in both lists.
        for info in owned { append(info, origin: "owned") }
        for sharedDoc in shared.items { append(sharedDoc.document, origin: "shared") }

        return try decodeSummary(ItemsEnvelope<DocumentSummary>.self, from: ["items": merged]).items
    }
}

// MARK: - Aliased document create/upsert

/// Identifies a document alias. The app-facing typed counterpart of the
/// client's ``AliasRef`` (`scope` + `aliasKey`, optional `userId`).
public struct DocumentAlias: Sendable, Hashable {
    public enum Scope: String, Sendable { case app, user }

    public let scope: Scope
    public let aliasKey: String
    /// Only meaningful for `.user` scope; defaults to the current user.
    public let userId: String?

    public init(scope: Scope, aliasKey: String, userId: String? = nil) {
        self.scope = scope
        self.aliasKey = aliasKey
        self.userId = userId
    }

    /// Project into the client's ``AliasRef``.
    fileprivate var ref: AliasRef {
        AliasRef(
            scope: scope == .user ? .user : .app,
            aliasKey: aliasKey,
            userId: userId
        )
    }
}

/// The alias record echoed back on an ``AliasedDocument``.
public struct AliasInfo: Decodable, Sendable, Hashable {
    public let scope: String
    public let aliasKey: String
    public let documentId: String?
    public let userId: String?
    public let createdAt: String?
}

/// Typed result of `documents.getOrCreateWithAlias` — the upserted document
/// plus whether this call created it (`created == false` ⇒ it already existed).
public struct AliasedDocument: Decodable, Sendable, Identifiable, Hashable {
    public let documentId: String
    public let created: Bool
    public let alias: AliasInfo
    public let title: String?
    public let createdBy: String?
    public let createdAt: String?
    public let modifiedAt: String?

    public var id: String { documentId }
}

extension DocumentsAPI {
    /// Atomic alias upsert: takes the app's typed ``DocumentAlias`` and returns
    /// a typed ``AliasedDocument``. Prefer this over a `resolve` +
    /// `createWithAlias` two-step.
    public func getOrCreateWithAlias(
        alias: DocumentAlias,
        title: String? = nil,
        tags: [String]? = nil
    ) async throws -> AliasedDocument {
        let result = try await getOrCreateWithAlias(options: GetOrCreateWithAliasOptions(
            alias: alias.ref,
            title: title,
            tags: tags
        ))
        var aliasDict: [String: Any] = [
            "scope": result.alias.scope.rawValue,
            "aliasKey": result.alias.aliasKey,
            "documentId": result.alias.documentId,
        ]
        if let userId = result.alias.userId { aliasDict["userId"] = userId }
        if let createdAt = result.alias.createdAt { aliasDict["createdAt"] = createdAt }
        var dict: [String: Any] = [
            "documentId": result.documentId,
            "created": result.created,
            "alias": aliasDict,
        ]
        if let title = result.title { dict["title"] = title }
        if let createdBy = result.createdBy { dict["createdBy"] = createdBy }
        if let createdAt = result.createdAt { dict["createdAt"] = createdAt }
        if let modifiedAt = result.modifiedAt { dict["modifiedAt"] = modifiedAt }
        return try decodeSummary(AliasedDocument.self, from: dict)
    }
}
