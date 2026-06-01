import Foundation
import JsBaoClient

// MARK: - Typed read summaries
//
// The `JsBaoClient` read APIs (`me.accessibleDocuments`, `collections.list`,
// `collections.getAccess`, `documents.getPermissions`, the
// `listPendingInvitations` pair, …) return raw `[String: Any]` /
// `[[String: Any]]` straight off the wire. That pushes a documented-nowhere
// key contract onto every list/permission screen: callers guess whether the
// id is `collectionId` or `id`, whether the display name is `name` /
// `displayName` / `userName`, and which container key (`items` vs `members`)
// wraps the array — a whole class of silent-nil / wrong-key bugs the type
// system would otherwise catch.
//
// This file pins those shapes to `Decodable` structs with a documented field
// contract, plus thin typed wrappers over the existing dict-returning methods.
// The raw methods stay exactly as they are for edge cases; these are additive.
//
// Field names below were verified against the js-bao server handlers (not the
// app's defensive guesses):
//   - documents: `formatDocumentInfo` (document-helpers.ts) — `permission` is
//     ALWAYS present, including for owned docs (it's `"owner"`).
//   - document permissions: `userId, email, name, avatarUrl, permission,
//     grantedAt` (rich).
//   - collection access members: `userId, permission, addedAt, addedBy` only —
//     NO name/email. Hence the optional name/email on `MemberAccess`.

// MARK: Decoding support

/// Decodes a `Decodable` value from an already-parsed JSON object
/// (`[String: Any]` / `[[String: Any]]`), as returned by the raw client APIs.
/// Round-trips through `JSONSerialization` so the existing dict methods stay
/// the single source of transport truth.
private let summaryDecoder = JSONDecoder()

private func decodeSummary<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try summaryDecoder.decode(T.self, from: data)
}

// MARK: - DocumentSummary

/// One row from `me.accessibleDocuments(tag:)` or
/// `collections.listDocuments(collectionId:)`.
///
/// `permission` is always present on the wire (`"owner"` for owned docs), so
/// it's non-optional here — no need to default it. `origin` (`"owned"` /
/// `"shared"`) is injected client-side by `accessibleDocuments` and is absent
/// from `listDocuments`, hence optional.
public struct DocumentSummary: Decodable, Sendable, Identifiable, Hashable {
    public let documentId: String
    public let title: String
    public let permission: String
    // `/me/shared-documents` rows are slim — they carry documentId,
    // permission, grantedAt, grantedBy, title, source ONLY (see
    // me-controller `listSharedDocuments`). `createdBy` / `createdAt` /
    // `lastModified` are present on `owned-documents` / `documents.list`
    // rows but ABSENT on shared rows. They were declared non-optional,
    // so decoding `accessibleDocuments` threw a DecodingError the moment
    // the user had any shared doc — silently breaking every
    // "shared-with-me" reconcile. Optional so the slim shared shape
    // decodes cleanly.
    public let createdBy: String?
    public let createdAt: String?
    public let lastModified: String?

    /// `"owned"` / `"shared"` — only set by `accessibleDocuments`.
    public let origin: String?
    public let grantedAt: String?
    public let tags: [String]?
    public let thumbnailBlobId: String?
    /// Present on `listDocuments` rows; absent on `accessibleDocuments`.
    public let collectionId: String?
    public let addedAt: String?
    public let addedBy: String?

    public var id: String { documentId }

    /// `true` when this row came from `accessibleDocuments` and the current
    /// user owns the document.
    public var isOwned: Bool { origin == "owned" || permission == "owner" }

    private enum CodingKeys: String, CodingKey {
        case documentId, title, permission, createdBy, createdAt, lastModified
        case origin = "_origin"
        case grantedAt, tags, thumbnailBlobId, collectionId, addedAt, addedBy
    }
}

// MARK: - CollectionSummary

/// One row from `collections.list()`.
///
/// `permission` is hydrated from the caller's group membership and is only
/// present for collections the user is a member of (reader/writer); it's
/// absent for collections owned by the user, so it's optional. Treat a nil
/// `permission` as ownership.
public struct CollectionSummary: Decodable, Sendable, Identifiable, Hashable {
    public let collectionId: String
    public let name: String
    public let permission: String?
    public let description: String?
    public let collectionType: String?
    public let documentCount: Int?
    public let appId: String?
    public let contextId: String?
    public let createdBy: String?
    public let createdAt: String?
    public let modifiedAt: String?

    public var id: String { collectionId }

    private enum CodingKeys: String, CodingKey {
        case collectionId, name, permission, description, collectionType
        case documentCount, appId, contextId, createdBy, createdAt, modifiedAt
    }
}

// MARK: - PermissionEntry

/// One entry from `documents.getPermissions(documentId:)` — a live member with
/// a resolved identity. Document permissions are the rich shape: `email` and
/// `name` are populated. (Collection members use ``MemberAccess`` instead,
/// which lacks those.)
public struct PermissionEntry: Decodable, Sendable, Identifiable, Hashable {
    public let userId: String
    public let email: String?
    public let name: String?
    public let avatarUrl: String?
    public let permission: String
    public let grantedAt: String?

    public var id: String { userId }

    /// Best display label: name, then email, then the raw user id.
    public var displayLabel: String { name ?? email ?? userId }
}

// MARK: - MemberAccess / CollectionAccess

/// One member from `collections.getAccess(collectionId:)`'s `members` array.
///
/// Unlike ``PermissionEntry``, the server does NOT resolve name/email here —
/// only `userId` and `permission` (plus add metadata) are returned. `email`
/// and `name` are declared optional purely so a single UI row type can render
/// both shapes; for collection members they will be nil.
public struct MemberAccess: Decodable, Sendable, Identifiable, Hashable {
    public let userId: String
    public let permission: String
    public let addedAt: String?
    public let addedBy: String?
    public let email: String?
    public let name: String?

    public var id: String { userId }

    public var displayLabel: String { name ?? email ?? userId }
}

/// One group grant from `collections.getAccess(collectionId:)`'s `groups`
/// array.
public struct GroupAccess: Decodable, Sendable, Hashable {
    public let collectionId: String?
    public let groupType: String
    public let groupId: String
    public let permission: String
    public let grantedAt: String?
    public let grantedBy: String?
}

/// Full result of `collections.getAccess(collectionId:)`.
public struct CollectionAccess: Decodable, Sendable {
    public let members: [MemberAccess]
    public let groups: [GroupAccess]

    private enum CodingKeys: String, CodingKey {
        case members, groups
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = try c.decodeIfPresent([MemberAccess].self, forKey: .members) ?? []
        groups = try c.decodeIfPresent([GroupAccess].self, forKey: .groups) ?? []
    }
}

// MARK: - PendingInvitation

/// One row from either `documents.listPendingInvitations(documentId:)` or
/// `collections.listPendingInvitations(collectionId:)` — they share a shape.
/// The "who invited" field is `grantedBy` for documents and `addedBy` for
/// collections; ``invitedBy`` coalesces the two.
public struct PendingInvitation: Decodable, Sendable, Identifiable, Hashable {
    public let email: String
    public let permission: String
    public let invitationId: String?
    public let createdAt: String?
    public let expiresAt: String?
    public let grantedBy: String?
    public let addedBy: String?

    public var id: String { invitationId ?? "pending-\(email)" }

    public var invitedBy: String? { grantedBy ?? addedBy }
}

// MARK: - Paginated-list container

/// `{ "items": [...] }` envelope used by most list endpoints.
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
        let owned = try await ownedTask
        let shared = try await sharedTask

        // Tolerate both list envelopes: current servers return
        // `{ items, cursor }`; older deployments return `{ documents, nextCursor }`.
        func rows(_ envelope: [String: Any]) -> [[String: Any]] {
            (envelope["items"] as? [[String: Any]])
                ?? (envelope["documents"] as? [[String: Any]])
                ?? []
        }

        var merged: [[String: Any]] = []
        var seen = Set<String>()
        func append(_ items: [[String: Any]], origin: String) {
            for var item in items {
                guard let id = item["documentId"] as? String else { continue }
                if seen.insert(id).inserted {
                    item["_origin"] = origin
                    merged.append(item)
                }
            }
        }
        // Owned appended first so it wins for any doc present in both lists.
        append(rows(owned), origin: "owned")
        append(rows(shared), origin: "shared")

        return try decodeSummary(ItemsEnvelope<DocumentSummary>.self, from: ["items": merged]).items
    }
}

// MARK: - Typed wrappers: CollectionsAPI

extension CollectionsAPI {
    /// Typed form of ``list(options:)``.
    public func listSummaries(
        options: PaginationOptions? = nil
    ) async throws -> [CollectionSummary] {
        let raw = try await list(options: options)
        return try decodeSummary(ItemsEnvelope<CollectionSummary>.self, from: raw).items
    }

    /// Typed form of ``listDocuments(collectionId:options:)``.
    public func listDocumentSummaries(
        collectionId: String,
        options: PaginationOptions? = nil
    ) async throws -> [DocumentSummary] {
        let raw = try await listDocuments(collectionId: collectionId, options: options)
        return try decodeSummary(ItemsEnvelope<DocumentSummary>.self, from: raw).items
    }

    /// Typed form of ``getAccess(collectionId:)``.
    public func accessSummary(collectionId: String) async throws -> CollectionAccess {
        let raw = try await getAccess(collectionId: collectionId)
        return try decodeSummary(CollectionAccess.self, from: raw)
    }

    /// Typed form of ``listPendingInvitations(collectionId:)``.
    public func pendingInvitationSummaries(
        collectionId: String
    ) async throws -> [PendingInvitation] {
        let raw = try await listPendingInvitations(collectionId: collectionId)
        return try decodeSummary([PendingInvitation].self, from: raw)
    }
}

// MARK: - Typed wrappers: DocumentsAPI

extension DocumentsAPI {
    /// Typed form of ``getPermissions(documentId:)``.
    public func permissionSummaries(documentId: String) async throws -> [PermissionEntry] {
        let raw = try await getPermissions(documentId: documentId)
        return try decodeSummary([PermissionEntry].self, from: raw)
    }

    /// Typed form of ``listPendingInvitations(documentId:)``.
    public func pendingInvitationSummaries(
        documentId: String
    ) async throws -> [PendingInvitation] {
        let raw = try await listPendingInvitations(documentId: documentId)
        return try decodeSummary([PendingInvitation].self, from: raw)
    }
}

// MARK: - Identity summaries (CurrentUser / UserProfile)

/// The signed-in user, from `me.get()`. Field names match the `/me`
/// response (`userId`, `email`, `name`); `name`/`avatarUrl` are optional
/// since the server may omit them.
public struct CurrentUser: Decodable, Sendable, Identifiable, Hashable {
    public let userId: String
    public let email: String
    public let name: String?
    public let avatarUrl: String?

    public var id: String { userId }
    public var displayLabel: String { name ?? email }
}

/// Another user's public profile, from `users.getBasic` / `lookup` /
/// `getProfiles`. Mirrors the server `UserProfile` shape (`userId`,
/// `email`, nullable `name`/`avatarUrl`).
public struct UserProfile: Decodable, Sendable, Identifiable, Hashable {
    public let userId: String
    public let email: String
    public let name: String?
    public let avatarUrl: String?

    public var id: String { userId }
    public var displayLabel: String { name ?? email }
}

/// One invitation addressed **to** the current user, from
/// `me.pendingDocumentInvitations()`. Unlike ``PendingInvitation`` (an
/// invite *on* a doc you own), this carries which document the invite is
/// for, so an inbox UI can show it.
public struct IncomingInvitation: Decodable, Sendable, Identifiable, Hashable {
    public let invitationId: String
    public let documentId: String
    public let title: String?
    public let email: String
    public let permission: String
    public let invitedBy: String?
    public let expiresAt: String?

    public var id: String { invitationId }
}

extension MeAPI {
    /// Typed form of ``get(options:)`` — the signed-in user, or `nil`
    /// when unauthenticated.
    public func currentUser() async throws -> CurrentUser? {
        guard let raw = try await get() else { return nil }
        return try decodeSummary(CurrentUser.self, from: raw)
    }

    /// Typed form of ``pendingDocumentInvitations()`` — document invites
    /// addressed to the current user (their "invitation inbox").
    public func pendingDocumentInvitationSummaries() async throws -> [IncomingInvitation] {
        let raw = try await pendingDocumentInvitations()
        return try decodeSummary([IncomingInvitation].self, from: raw)
    }
}

extension UsersAPI {
    /// Typed form of ``getBasic(userId:options:)`` — `nil` if the user
    /// isn't found in this app.
    public func profile(userId: String, options: FetchCachedOptions? = nil) async throws -> UserProfile? {
        let raw = try await getBasic(userId: userId, options: options)
        guard !raw.isEmpty else { return nil }
        return try decodeSummary(UserProfile.self, from: raw)
    }

    /// Typed form of ``lookup(email:)`` — the matching user, or `nil`.
    public func profile(email: String) async throws -> UserProfile? {
        let raw = try await lookup(email: email)
        return try decodeSummary(ItemsEnvelope<UserProfile>.self, from: raw).items.first
    }

    /// Typed form of ``getProfiles(userIds:)`` — batch lookup; missing
    /// users are silently omitted.
    public func profiles(userIds: [String]) async throws -> [UserProfile] {
        let raw = try await getProfiles(userIds: userIds)
        return try decodeSummary([UserProfile].self, from: raw)
    }
}

// MARK: - Aliased document create/upsert

/// Identifies a document alias. Typed counterpart of the `[String: Any]`
/// `alias` dict the raw API takes (`scope` + `aliasKey`, optional `userId`).
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

    fileprivate var dict: [String: Any] {
        var d: [String: Any] = ["scope": scope.rawValue, "aliasKey": aliasKey]
        if let userId { d["userId"] = userId }
        return d
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
    /// Typed form of ``getOrCreateWithAlias(alias:title:tags:)``. Takes a typed
    /// ``DocumentAlias`` and returns a typed ``AliasedDocument`` (the raw
    /// overload returns `[String: Any]`). This is the atomic upsert — prefer it
    /// over a `resolve` + `createWithAlias` two-step.
    public func getOrCreateWithAlias(
        alias: DocumentAlias,
        title: String? = nil,
        tags: [String]? = nil
    ) async throws -> AliasedDocument {
        let raw = try await getOrCreateWithAlias(alias: alias.dict, title: title, tags: tags)
        return try decodeSummary(AliasedDocument.self, from: raw)
    }
}
