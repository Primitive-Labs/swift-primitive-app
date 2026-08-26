#if DEBUG
import Foundation
import JsBaoClient

// MARK: - Typed-result → `[String: Any]` mapping for the debug inspector
//
// The debug inspector serves raw JSON to its in-browser UI via
// `JSONSerialization.data(withJSONObject:)`, which only accepts Foundation
// value types (String / NSNumber / Array / Dictionary / NSNull). The
// `JsBaoClient` read APIs now return typed Swift structs (`CollectionInfo`,
// `DatabaseInfo`, …) instead of the raw dictionaries they used to. These
// `inspectorDict` shims project each typed result back into the plain
// dictionary shape the inspector UI already understands, so the migration to
// typed client results is invisible to the HTML/JS layer.
//
// DEBUG-only: the inspector itself is `#if DEBUG`, so none of this ships in
// release builds.

/// Convert a `JSONValue` (the client's opaque-JSON wrapper) into a
/// `JSONSerialization`-safe `Any`. `nil` / `.null` become `NSNull()`.
func inspectorAny(_ value: JSONValue?) -> Any {
    guard let value, !value.isNull else { return NSNull() }
    if let object = value.objectValue { return object.mapValues { inspectorAny($0) } }
    if let array = value.arrayValue { return array.map { inspectorAny($0) } }
    if let string = value.stringValue { return string }
    if let number = value.numberValue { return number }
    if let bool = value.boolValue { return bool }
    return NSNull()
}

/// Convert a `JSONSerialization`-parsed `Any` (as the inspector receives from
/// the browser) into a `JSONValue` for typed client params. Returns `nil` for
/// `nil` / `NSNull` / values that don't round-trip through JSON.
func inspectorJSONValue(from any: Any?) -> JSONValue? {
    guard let any, !(any is NSNull) else { return nil }
    guard JSONSerialization.isValidJSONObject(any),
          let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

/// Drop `nil` values so the inspector dicts stay `JSONSerialization`-safe and
/// don't carry spurious `NSNull`s for absent optionals.
private func compactDict(_ pairs: [String: Any?]) -> [String: Any] {
    pairs.compactMapValues { $0 }
}

extension CollectionInfo {
    // `contextId` is not projected: the client deprecated it in favour of
    // resource metadata categories (issue #1420), which the inspector reads
    // under `md.self.<category>.<key>` rather than as a collection field.
    var inspectorDict: [String: Any] {
        compactDict([
            "collectionId": collectionId,
            "appId": appId,
            "name": name,
            "description": description,
            "collectionType": collectionType,
            "documentCount": documentCount,
            "createdAt": createdAt,
            "createdBy": createdBy,
            "modifiedAt": modifiedAt,
            "permission": permission?.rawValue,
        ])
    }
}

extension CollectionDocumentInfo {
    var inspectorDict: [String: Any] {
        compactDict([
            "documentId": documentId,
            "collectionId": collectionId,
            "addedAt": addedAt,
            "addedBy": addedBy,
            "title": title,
            "createdBy": createdBy,
            "createdAt": createdAt,
            "lastModified": lastModified,
            "permission": permission?.rawValue,
            "tags": tags,
        ])
    }
}

extension DatabaseInfo {
    var inspectorDict: [String: Any] {
        var dict = compactDict([
            "databaseId": databaseId,
            "title": title,
            "databaseType": databaseType,
            "permission": permission,
            "createdBy": createdBy,
            "createdAt": createdAt,
            "modifiedAt": modifiedAt,
        ])
        // `celContext` is not projected: the client deprecated it in favour of
        // resource metadata categories (issue #1420). `metadata` is the same
        // server field under its legacy wire name and is not deprecated on
        // `DatabaseInfo`, so the CEL-context values stay visible in the
        // inspector under that key.
        if metadata != nil { dict["metadata"] = inspectorAny(metadata) }
        return dict
    }
}

extension DatabaseOperationInfo {
    var inspectorDict: [String: Any] {
        var dict = compactDict([
            "databaseId": databaseId,
            "name": name,
            "type": type.rawValue,
            "modelName": modelName,
            "access": access,
            "createdBy": createdBy,
            "createdAt": createdAt,
            "modifiedAt": modifiedAt,
        ])
        dict["definition"] = inspectorAny(definition)
        if params != nil { dict["params"] = inspectorAny(params) }
        return dict
    }
}

extension ModelFieldInfo {
    var inspectorDict: [String: Any] {
        [
            "modelName": modelName,
            "fieldName": fieldName,
            "inferredType": inferredType,
            "firstSeenAt": firstSeenAt,
        ]
    }
}

extension DocumentPermissionEntry {
    // `name` is optional on the wire — a user provisioned through the
    // email-code flow has none (#2980) — so the key is dropped rather than
    // projected as a null.
    var inspectorDict: [String: Any] {
        compactDict([
            "userId": userId,
            "email": email,
            "name": name,
            "permission": permission.rawValue,
            "grantedAt": grantedAt,
        ])
    }
}

extension PendingInvitationEntry {
    var inspectorDict: [String: Any] {
        compactDict([
            "email": email,
            "permission": permission,
            "invitationId": invitationId,
            "createdAt": createdAt,
            "expiresAt": expiresAt,
            "grantedBy": grantedBy,
        ])
    }
}

extension CollectionGroupPermissionInfo {
    var inspectorDict: [String: Any] {
        [
            "collectionId": collectionId,
            "groupType": groupType,
            "groupId": groupId,
            "permission": permission,
            "grantedAt": grantedAt,
            "grantedBy": grantedBy,
        ]
    }
}

extension CollectionMemberInfo {
    var inspectorDict: [String: Any] {
        compactDict([
            "userId": userId,
            "permission": permission,
            "addedAt": addedAt,
            "addedBy": addedBy,
        ])
    }
}

extension CollectionAccessInfo {
    var inspectorDict: [String: Any] {
        [
            "groups": groups.map { $0.inspectorDict },
            "members": members.map { $0.inspectorDict },
        ]
    }
}

extension BlobInfo {
    var inspectorDict: [String: Any] {
        compactDict([
            "blobId": blobId,
            "filename": filename,
            "contentType": contentType,
            "numBytes": numBytes,
            "sha256": sha256,
            "createdAt": createdAt,
            "disposition": disposition,
        ])
    }
}
#endif
