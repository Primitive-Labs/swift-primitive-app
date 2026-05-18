// This file is always compiled (no `#if DEBUG`) so release builds can still import
// the protocol types — the runtime machinery that uses them lives inside
// `#if DEBUG` in DebugInspector.swift, so there's no release overhead.
import Foundation
import JsBaoClient

/// A field on an inspectable model, used by the debug inspector to render typed columns.
public struct InspectableField: Sendable {
    public enum Kind: String, Sendable {
        case string
        case number
        case boolean
        case json
        case date
        case id
        /// Runtime-schema `stringset` — a `Set<String>` persisted via a per-field junction
        /// table. Rendered by the inspector as a comma-joined list.
        case stringset
    }
    public let name: String
    public let kind: Kind
    public let optional: Bool

    public init(name: String, kind: Kind, optional: Bool = false) {
        self.name = name
        self.kind = kind
        self.optional = optional
    }
}

/// A live read-only handle to the in-memory SQL projection that backs a model.
///
/// The query engine maintains a real `:memory:` SQLite database — one table per model,
/// kept in sync with the Y.Doc via the update observer — and that's what powers
/// `model.query(filter:)`, `count`, `aggregate`, etc. Surfacing it lets the inspector
/// show users the *actual* indexed projection, not just the records as YMap keys.
///
/// Closures rather than direct engine access keeps `JsBaoClient` types out of the
/// inspector's HTTP plumbing and lets callers swap in fakes for tests.
public struct InspectableMemoryDB: Sendable {

    /// The SQL identifier of this model's main table (e.g. `"tasks"`).
    public let tableName: String

    /// Lists every table currently registered in the engine (main rows + junction
    /// tables for stringset fields). Same engine instance may host multiple models
    /// when shared across docs, so this surfaces what's actually present.
    public let listTables: @Sendable () -> [String]

    /// Column descriptors for a given table. Pulled via `PRAGMA table_info(...)`.
    public let columns: @Sendable (_ table: String) -> [InspectableSQLColumn]

    /// Up-to-`limit` rows for a given table. Each dict is the raw SQL row —
    /// values are already coerced to Swift types by the engine's `executeQuery`.
    public let rows: @Sendable (_ table: String, _ limit: Int) -> [[String: Any]]

    /// Total row count for a given table. Faster than fetching rows just to count.
    public let rowCount: @Sendable (_ table: String) -> Int

    /// Run an arbitrary read-only SQL string against the engine and return the
    /// raw row dicts. Caller is responsible for validating that the SQL is
    /// read-only — direct DML against the engine would desync the projection
    /// from its Y.Doc source of truth.
    public let executeQuery: @Sendable (_ sql: String) -> [[String: Any]]

    public init(
        tableName: String,
        listTables: @escaping @Sendable () -> [String],
        columns: @escaping @Sendable (String) -> [InspectableSQLColumn],
        rows: @escaping @Sendable (String, Int) -> [[String: Any]],
        rowCount: @escaping @Sendable (String) -> Int,
        executeQuery: @escaping @Sendable (String) -> [[String: Any]]
    ) {
        self.tableName = tableName
        self.listTables = listTables
        self.columns = columns
        self.rows = rows
        self.rowCount = rowCount
        self.executeQuery = executeQuery
    }
}

/// SQLite column descriptor, mirroring `PRAGMA table_info`.
public struct InspectableSQLColumn: Sendable {
    public let name: String
    public let type: String
    public let notNull: Bool
    public let isPrimaryKey: Bool

    public init(name: String, type: String, notNull: Bool, isPrimaryKey: Bool) {
        self.name = name
        self.type = type
        self.notNull = notNull
        self.isPrimaryKey = isPrimaryKey
    }
}

/// One model surfaced to the debug inspector.
///
/// The host app exposes one of these per model it wants the inspector to render. We erase
/// the record type here (`[String: Any]` round-trip) so the inspector stays generic — apps
/// using the legacy `BaoModel<T>` path AND apps using the runtime-schema
/// `DynamicModel` / `TypedModel<T>` path both produce the same shape.
public struct InspectableModel: @unchecked Sendable {

    public let name: String
    public let documentId: String
    public let fields: [InspectableField]

    /// Returns every record as a dictionary. Called on the main actor because the
    /// underlying model reads from a Y.Doc that should only be touched there.
    public let loadAll: @MainActor () -> [[String: Any]]

    /// Optional — delete a record by id. If `nil`, the inspector renders the model as
    /// read-only (no delete buttons).
    public let deleteById: (@MainActor (String) -> Void)?

    /// Optional — create a record from a raw `[String: Any]` dict (same shape the
    /// inspector uses to render rows). Returns the new record's id. Throws on
    /// validation / uniqueness / wiring errors so the UI can surface the message.
    /// When `nil`, the inspector hides its "new record" button for this model.
    public let createWith: (@MainActor ([String: Any]) throws -> String)?

    /// Optional — handle to the in-memory SQL projection that backs this model's
    /// queries. Wired up by the `DynamicModel` factory (since legacy `BaoModel<T>`
    /// uses a different mirror lifecycle); the inspector's "Memory SQL" tab only
    /// shows models that surface one of these.
    public let memoryDB: InspectableMemoryDB?

    public init(
        name: String,
        documentId: String,
        fields: [InspectableField],
        loadAll: @escaping @MainActor () -> [[String: Any]],
        deleteById: (@MainActor (String) -> Void)? = nil,
        createWith: (@MainActor ([String: Any]) throws -> String)? = nil,
        memoryDB: InspectableMemoryDB? = nil
    ) {
        self.name = name
        self.documentId = documentId
        self.fields = fields
        self.loadAll = loadAll
        self.deleteById = deleteById
        self.createWith = createWith
        self.memoryDB = memoryDB
    }
}

/// Conformance opt-in for a `PrimitiveAppState` subclass that wants the debug inspector to
/// display its models. The base class returns `[]`; override in your subclass to surface
/// your models. See `DemoAppState` in the demo for the canonical shape.
///
/// Mix of `BaoModel<T>` (legacy typed) and `TypedModel<T>` / `DynamicModel` (runtime
/// schema) is supported — each has its own `InspectableModel.from(...)` factory. The
/// inspector itself sees only the erased `[[String: Any]]` rows and doesn't care which
/// API produced them.
public protocol InspectableModelHost: AnyObject {
    @MainActor var inspectableModels: [InspectableModel] { get }
}

/// Default conformance — the base class's `inspectableModels` property reads
/// from the registry populated by `makeTypedModel(...)`, so every
/// `PrimitiveAppState` (and subclass) is an `InspectableModelHost` out of the
/// box. Subclasses can still `override inspectableModels` if they need custom
/// logic.
extension PrimitiveAppState: InspectableModelHost {}

// MARK: - Legacy BaoModel<T> bridge

public extension InspectableModel {
    /// Build an `InspectableModel` from a typed legacy `BaoModel<T>`. The record type
    /// supplies the field definitions via its `BaoModelRecord` conformance; `loadAll`
    /// serializes records through `toFields()` so the inspector gets a generic
    /// `[[String: Any]]` without needing to know `T`. `deleteById` is wired to
    /// `BaoModel.delete(_:)`.
    @MainActor
    static func from<T: BaoModelRecord>(
        _ model: BaoModel<T>,
        documentId: String,
        name: String? = nil
    ) -> InspectableModel {
        let fields: [InspectableField] = T.fields.map { def in
            InspectableField(
                name: def.name,
                kind: kindForLegacy(def.type),
                optional: def.optional
            )
        }
        return InspectableModel(
            name: name ?? T.modelName,
            documentId: documentId,
            fields: fields,
            loadAll: { model.findAll().map { $0.toFields() } },
            deleteById: { id in model.delete(id) },
            createWith: { values in
                // Legacy BaoModelRecord builds itself from a `[String: Any]` via
                // `init(fields:)`. Generate an id if the caller didn't supply one.
                var dict = values
                let supplied = dict["id"] as? String
                if supplied == nil || supplied?.isEmpty == true {
                    dict["id"] = generateULID()
                }
                let record = T(fields: dict)
                model.create(record)
                return record.id
            }
        )
    }

    /// Map the legacy `BaoModelRecord` `FieldType` to the inspector's `Kind`.
    private static func kindForLegacy(_ type: FieldType) -> InspectableField.Kind {
        switch type {
        case .string:  return .string
        case .number:  return .number
        case .boolean: return .boolean
        case .json:    return .json
        }
    }
}

// MARK: - Runtime-schema bridge (DynamicModel / TypedModel<T>)

public extension InspectableModel {

    /// Build an `InspectableModel` from a runtime-schema `DynamicModel`. Fields are
    /// derived from `model.schema`, and `loadAll` reads through `model.query()` — which
    /// uses the SQLite mirror so results arrive as the plain `[String: Any]` rows the
    /// inspector already understands (stringsets arrive as `[String]`).
    ///
    /// The `_meta_doc_id` bookkeeping column that the shared-engine query layer adds
    /// is stripped from the rows the inspector sees — it's an internal sharding key,
    /// not a user-visible field.
    @MainActor
    static func from(
        _ model: DynamicModel,
        documentId: String,
        name: String? = nil
    ) -> InspectableModel {
        let schema = model.schema
        let fields: [InspectableField] = schema.fields
            .sorted { lhs, rhs in orderField(lhs.key) < orderField(rhs.key) }
            .map { (fieldName, desc) in
                InspectableField(
                    name: fieldName,
                    kind: kindForRuntime(desc.type),
                    optional: !desc.required
                )
            }
        // Capture the engine handle once so closures don't have to walk
        // through `model` each call. `inspectionQueryEngine` is the public
        // accessor introduced for exactly this purpose; treat it as read-only.
        let engine = model.inspectionQueryEngine
        let mainTable = model.inspectionTableName
        let memoryDB = InspectableMemoryDB(
            tableName: mainTable,
            listTables: {
                let rows = engine.rawQuery(
                    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
                )
                return rows.compactMap { $0["name"] as? String }
            },
            columns: { table in
                // PRAGMA table_info doesn't accept bind parameters — but the
                // table name is constrained to ones we just listed via
                // sqlite_master, so quoting+escaping is enough.
                //
                // The engine's `executeQuery` coerces SQLITE_INTEGER columns
                // to `Int` (not `Int64`), so cast to `Int` here. Casting to
                // the wrong width silently returns nil and every row reads as
                // false — which is what bit the rowCount path on first try.
                let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
                let rows = engine.rawQuery("PRAGMA table_info(\"\(escaped)\")")
                return rows.map { row in
                    InspectableSQLColumn(
                        name: (row["name"] as? String) ?? "",
                        type: (row["type"] as? String) ?? "",
                        notNull: ((row["notnull"] as? Int) ?? 0) != 0,
                        isPrimaryKey: ((row["pk"] as? Int) ?? 0) != 0
                    )
                }
            },
            rows: { table, limit in
                let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
                return engine.rawQuery("SELECT * FROM \"\(escaped)\" LIMIT \(max(0, limit))")
            },
            rowCount: { table in
                let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
                let rows = engine.rawQuery("SELECT COUNT(*) AS c FROM \"\(escaped)\"")
                return (rows.first?["c"] as? Int) ?? 0
            },
            executeQuery: { sql in
                engine.rawQuery(sql)
            }
        )
        return InspectableModel(
            name: name ?? schema.name,
            documentId: documentId,
            fields: fields,
            loadAll: {
                model.query().map { row in
                    var out = row
                    out.removeValue(forKey: "_meta_doc_id")
                    return out
                }
            },
            deleteById: { id in model.delete(id: id) },
            createWith: { values in
                // Convert caller-supplied `[String: Any]` into the
                // `[String: PrimitiveValue]` shape `DynamicModel.create`
                // expects, routing through the schema so each field gets
                // wrapped in the right PrimitiveValue case.
                var wrapped: [String: PrimitiveValue] = [:]
                for (fieldName, raw) in values {
                    guard let desc = schema.fields[fieldName] else { continue }
                    if let pv = primitiveValue(from: raw, type: desc.type) {
                        wrapped[fieldName] = pv
                    }
                }
                let record = try model.create(values: wrapped)
                return record.id
            },
            memoryDB: memoryDB
        )
    }

    /// Convenience overload — `TypedModel<T>` is a thin façade over a `DynamicModel`,
    /// so we just unwrap it.
    @MainActor
    static func from<T: PrimitiveModel>(
        _ model: TypedModel<T>,
        documentId: String,
        name: String? = nil
    ) -> InspectableModel {
        return from(model.dynamic, documentId: documentId, name: name ?? T.modelName)
    }

    /// Map the runtime-schema `PrimitiveFieldType` to the inspector's `Kind`.
    private static func kindForRuntime(_ type: PrimitiveFieldType) -> InspectableField.Kind {
        switch type {
        case .string:    return .string
        case .number:    return .number
        case .boolean:   return .boolean
        case .date:      return .date
        case .id:        return .id
        case .stringset: return .stringset
        case .json:      return .json
        }
    }

    /// Column ordering heuristic: `id` first, then the rest alphabetical. Keeps the
    /// inspector table readable regardless of which order fields appear in the schema
    /// dictionary (which is unordered).
    private static func orderField(_ name: String) -> String {
        name == "id" ? "\u{0001}\(name)" : name
    }

    /// Wrap a raw `[String: Any]` field value (as produced by JSON-decoding the
    /// inspector's create form) into the `PrimitiveValue` case the runtime-schema
    /// `DynamicModel.create` expects. Returns `nil` for values we can't sensibly
    /// coerce — the caller drops unconvertible fields rather than writing a
    /// nonsensical value.
    internal static func primitiveValue(from raw: Any, type: PrimitiveFieldType) -> PrimitiveValue? {
        if raw is NSNull { return nil }
        switch type {
        case .string:
            if let s = raw as? String { return .string(s) }
        case .number:
            if let d = raw as? Double { return .number(d) }
            if let i = raw as? Int    { return .number(Double(i)) }
            if let i = raw as? Int64  { return .number(Double(i)) }
            if let s = raw as? String, let d = Double(s) { return .number(d) }
        case .boolean:
            if let b = raw as? Bool { return .boolean(b) }
            if let s = raw as? String { return .boolean(s == "true") }
        case .id:
            if let s = raw as? String, !s.isEmpty { return .id(s) }
        case .date:
            if let s = raw as? String { return .date(s) }
        case .stringset:
            if let arr = raw as? [String] { return .stringset(Set(arr)) }
            if let s = raw as? String {
                let members = s.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return .stringset(Set(members))
            }
        case .json:
            if let s = raw as? String { return .json(Data(s.utf8)) }
            if let d = raw as? Data { return .json(d) }
            if JSONSerialization.isValidJSONObject(raw),
               let data = try? JSONSerialization.data(withJSONObject: raw) {
                return .json(data)
            }
        }
        return nil
    }
}
