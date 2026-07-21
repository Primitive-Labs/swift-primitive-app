import Foundation
import JsBaoClient

// MARK: - Typed read summaries
//
// The `JsBaoClient` read APIs now return typed `Decodable` structs
// (`DocumentInfo`, `SharedDocumentListResult`, `CollectionInfo`, …) directly,
// so the app-side typed wrappers that used to re-shape raw `[String: Any]`
// responses are redundant — call the client's typed methods instead.
//
// What stays here is the typed `getOrCreateWithAlias(alias:)` overload: it
// takes the app's typed ``DocumentAlias`` and returns a typed
// ``AliasedDocument``.
//
// There is intentionally no merged "accessible documents" wrapper — compose
// `me.ownedDocuments` + `me.sharedDocuments` at the call site (1:1 with the JS
// app layer, which exposes no merged helper either).

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


// MARK: - Aliased document create/upsert

/// Identifies a document alias. The app-facing typed counterpart of the
/// client's ``AliasRef`` (`scope` + `aliasKey`, optional `userId`).
public struct DocumentAlias: Sendable, Hashable {
    /// Only user scope exists — app-scoped aliases were removed in
    /// js-bao-wss #1168.
    public enum Scope: String, Sendable { case user }

    public let scope: Scope
    public let aliasKey: String
    /// Defaults to the current user.
    public let userId: String?

    public init(scope: Scope = .user, aliasKey: String, userId: String? = nil) {
        self.scope = scope
        self.aliasKey = aliasKey
        self.userId = userId
    }

    /// Project into the client's ``AliasRef``.
    fileprivate var ref: AliasRef {
        AliasRef(
            scope: .user,
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
