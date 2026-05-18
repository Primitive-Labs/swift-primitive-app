#if DEBUG
import Foundation
import SQLite3

/// Read-only SQLite inspector for the JsBaoClient's kv_store database.
///
/// The client keeps its offline data in `<docs>/JsBaoClient/<appId>:<userId>/jsbao_storage.sqlite`
/// with a single `kv_store(store, key, value, metadata, updated_at)` table. The namespace
/// (`appId:userId`) is only known after auth, so we scan for directories that start with
/// `<appId>:` and pick the most-recently-modified one.
///
/// WAL mode is enabled by the writer, which means a read-only handle from this process can
/// safely coexist with the writer handle — no lock contention, and we see committed state.
struct InspectorSQLiteReader {

    let appId: String

    // MARK: - Public surface

    struct StoreInfo {
        let name: String
        let rowCount: Int
    }

    struct Row {
        let key: String
        let value: String
        let metadata: String?
        let updatedAt: String?
    }

    /// Absolute path to the SQLite file, or nil if no matching directory exists yet
    /// (e.g. the user hasn't logged in, so no `appId:userId` folder has been created).
    func resolveDatabasePath() -> String? {
        resolve().path
    }

    /// Full diagnostic payload: what roots we tried, what namespace dirs we
    /// found for this appId, and which path (if any) we resolved. Surfaced
    /// in the inspector's SQLite tab so a blank view is self-diagnosing —
    /// the dev can see whether we failed at "no root", "no matching
    /// namespace dir", "file missing under the dir", or "file opens but
    /// has no kv_store table".
    struct ResolutionDiagnostic {
        let appId: String
        let candidateRoots: [String]
        /// Per-root: the filtered list of `appId:*` subdirs with modification dates.
        let candidates: [(root: String, subdirs: [(name: String, mtime: Date)])]
        let path: String?
        /// Probe results against the resolved path. `nil` when `path` is nil.
        /// When non-nil, reports whether we could open the file, what tables
        /// exist, and — if `kv_store` is there — its row count. Makes the
        /// three "blank panel" failure modes distinguishable at a glance:
        ///   - path nil                       → no file yet
        ///   - openError non-nil              → path exists but can't open
        ///   - tables doesn't include kv_store → file is something else
        ///   - kvStoreRows == 0                → table exists, just empty
        let probe: FileProbe?
    }

    struct FileProbe {
        let fileSize: Int?
        let walFileSize: Int?
        let shmFileSize: Int?
        let openError: String?
        let journalMode: String?
        let tables: [String]
        /// Row counts observed from the reader's fresh connection.
        /// `kvStoreRowsPre` is what `SELECT COUNT(*)` returns immediately
        /// after opening; `kvStoreRowsPost` is after running a passive
        /// wal_checkpoint. If they disagree, the reader's view of the
        /// WAL is lagging the writer's — we're in an iOS-simulator
        /// WAL-visibility edge case.
        let kvStoreRowsPre: Int?
        let kvStoreRowsPost: Int?
        let walCheckpointResult: String?
    }

    func resolve() -> ResolutionDiagnostic {
        let roots = candidateRoots() ?? []
        var candidates: [(String, [(String, Date)])] = []
        var resolvedPath: String?
        for root in roots {
            let subdirs = matchingSubdirs(in: root)
            candidates.append((root, subdirs))
            if resolvedPath == nil, let best = subdirs.first {
                let dir = (root as NSString).appendingPathComponent(best.name)
                let dbPath = (dir as NSString).appendingPathComponent("jsbao_storage.sqlite")
                if FileManager.default.fileExists(atPath: dbPath) {
                    resolvedPath = dbPath
                }
            }
        }
        let probe = resolvedPath.map { probeFile(at: $0) }
        return ResolutionDiagnostic(
            appId: appId,
            candidateRoots: roots,
            candidates: candidates,
            path: resolvedPath,
            probe: probe
        )
    }

    /// Opens the resolved SQLite file read-write (so WAL-mode rows are
    /// visible) and reports what's inside. Any failure is captured in
    /// `openError` so the UI can surface the actual sqlite errmsg
    /// instead of a generic blank panel.
    private func probeFile(at path: String) -> FileProbe {
        let fm = FileManager.default
        let fileSize    = try? fm.attributesOfItem(atPath: path)[.size] as? Int ?? nil
        let walFileSize = try? fm.attributesOfItem(atPath: path + "-wal")[.size] as? Int ?? nil
        let shmFileSize = try? fm.attributesOfItem(atPath: path + "-shm")[.size] as? Int ?? nil

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let db { sqlite3_close_v2(db) }
            return FileProbe(
                fileSize: fileSize ?? nil, walFileSize: walFileSize ?? nil, shmFileSize: shmFileSize ?? nil,
                openError: msg, journalMode: nil,
                tables: [], kvStoreRowsPre: nil, kvStoreRowsPost: nil,
                walCheckpointResult: nil
            )
        }
        defer { sqlite3_close_v2(db) }

        // Journal mode confirms WAL is actually in use. Anything else
        // changes our reasoning — e.g. MEMORY mode means writes live
        // only in the writer's process RAM.
        var journalMode: String?
        if let stmt = prepare(db: db, sql: "PRAGMA journal_mode") {
            if sqlite3_step(stmt) == SQLITE_ROW, let p = sqlite3_column_text(stmt, 0) {
                journalMode = String(cString: p)
            }
            sqlite3_finalize(stmt)
        }

        // Table list. If `kv_store` isn't here the reader is on the wrong
        // file; otherwise we move on to row counts.
        var tables: [String] = []
        if let stmt = prepare(db: db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let p = sqlite3_column_text(stmt, 0) { tables.append(String(cString: p)) }
            }
            sqlite3_finalize(stmt)
        }

        let kvStoreRowsPre = tables.contains("kv_store") ? countRows(db: db, table: "kv_store") : nil

        // WAL-visibility experiment. If `SELECT COUNT(*)` returns 0 but
        // the WAL file is non-trivial, the writer's committed rows may
        // not be visible to this fresh reader connection (iOS-simulator
        // + cross-connection WAL-index lag). A passive checkpoint
        // forces WAL frames that aren't pinned by other readers back
        // into the main DB, AND refreshes our connection's WAL view as
        // a side effect. A post-checkpoint count that differs from
        // `kvStoreRowsPre` is the smoking gun.
        var walCheckpointResult: String?
        var kvStoreRowsPost: Int?
        if tables.contains("kv_store") {
            var nLog: Int32 = 0
            var nCkpt: Int32 = 0
            let ckptRc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, &nLog, &nCkpt)
            walCheckpointResult = "rc=\(ckptRc) nLog=\(nLog) nCkpt=\(nCkpt)"
            kvStoreRowsPost = countRows(db: db, table: "kv_store")
        }

        return FileProbe(
            fileSize: fileSize ?? nil, walFileSize: walFileSize ?? nil, shmFileSize: shmFileSize ?? nil,
            openError: nil, journalMode: journalMode,
            tables: tables, kvStoreRowsPre: kvStoreRowsPre, kvStoreRowsPost: kvStoreRowsPost,
            walCheckpointResult: walCheckpointResult
        )
    }

    private func countRows(db: OpaquePointer, table: String) -> Int? {
        guard let stmt = prepare(db: db, sql: "SELECT COUNT(*) FROM \"\(table)\"") else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func prepare(db: OpaquePointer, sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK ? stmt : nil
    }

    /// List all `store` names found in the kv_store table along with their row counts.
    func listStores() -> [StoreInfo] {
        guard let dbPath = resolveDatabasePath() else {
            inspectorLog("sqlite: no resolved db path (not logged in yet?)", level: "warn")
            return []
        }
        return openReadOnly(dbPath) { db in
            // Refresh our view of the WAL before reading. See
            // `syncWalView` for the "why" — without this, iOS-simulator
            // readers can see the schema (CREATE TABLE committed to the
            // WAL) but miss later row-level INSERTs sitting in WAL
            // frames the reader's wal-index hasn't mapped.
            syncWalView(db)

            var results: [StoreInfo] = []
            let sql = "SELECT store, COUNT(*) FROM kv_store GROUP BY store ORDER BY store ASC"
            var stmt: OpaquePointer?
            let prc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard prc == SQLITE_OK else {
                // Most common failure mode: "no such table: kv_store" when
                // the client's SQLiteStorageProvider hasn't run
                // initialize() yet (pre-login) or when the reader is
                // looking at a file the client didn't write. Both show up
                // as blank panels without this log, so we surface it.
                let err = String(cString: sqlite3_errmsg(db))
                inspectorLog("sqlite: prepare listStores failed (\(dbPath)): \(err)", level: "error")
                return []
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
                let name = String(cString: namePtr)
                let count = Int(sqlite3_column_int64(stmt, 1))
                results.append(StoreInfo(name: name, rowCount: count))
            }
            return results
        } ?? []
    }

    /// Force our fresh SQLite connection's WAL-index view to catch up
    /// with whatever the writer has committed. Runs `PRAGMA
    /// wal_checkpoint(PASSIVE)` — non-blocking, pinned WAL frames stay
    /// put, unpinned frames get rolled into the main DB and made
    /// visible to this connection on the next query.
    ///
    /// Motivation: on iOS Simulator we reproducibly see a reader (same
    /// process, separate connection) that reads the schema correctly
    /// but misses row-level INSERTs because its `wal-index` snapshot
    /// was established before the writer's INSERT frame was appended.
    /// Passing a checkpoint clears that snapshot. This is a reader-only
    /// operation from our side — no writes attempted.
    private func syncWalView(_ db: OpaquePointer) {
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
    }

    /// Paginated rows from a given store, most-recently-updated first.
    func readStore(_ store: String, limit: Int, offset: Int) -> [Row] {
        guard let dbPath = resolveDatabasePath() else { return [] }
        return openReadOnly(dbPath) { db in
            syncWalView(db)                // see listStores() for motivation
            var results: [Row] = []
            // Order by updated_at DESC so the most recently written rows show up first.
            // NULLS LAST (via COALESCE to empty string) keeps rows with no timestamp at the bottom.
            let sql = """
                SELECT key, value, metadata, updated_at
                FROM kv_store
                WHERE store = ?
                ORDER BY COALESCE(updated_at, '') DESC, key ASC
                LIMIT ? OFFSET ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, store, -1, transient)
            sqlite3_bind_int(stmt, 2, Int32(max(1, min(limit, 500))))
            sqlite3_bind_int(stmt, 3, Int32(max(0, offset)))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let value = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let metadata = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let updatedAt = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                results.append(Row(key: key, value: value, metadata: metadata, updatedAt: updatedAt))
            }
            return results
        } ?? []
    }

    // MARK: - Private

    private func candidateRoots() -> [String]? {
        // Mirror SQLiteStorageProvider.defaultDirectory — documentDirectory on iOS,
        // applicationSupportDirectory on macOS. We try the likely one first, then the
        // other as a fallback for when tooling blurs the line (e.g. Mac Catalyst builds).
        let fm = FileManager.default
        var roots: [String] = []
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(docs.appendingPathComponent("JsBaoClient").path)
        }
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(support.appendingPathComponent("JsBaoClient").path)
        }
        return roots.isEmpty ? nil : roots
    }

    /// Matching `appId:*` subdirs sorted newest-first. Matches the "real"
    /// OfflineStore namespace shape (`appId:userId`), NOT the auth-scoped
    /// `auth:appId:userId` sibling dirs — those live in the same root but
    /// hold persisted JWTs, not the kv_store we want.
    private func matchingSubdirs(in root: String) -> [(name: String, mtime: Date)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let prefix = "\(appId):"
        let matches = entries.filter { $0.hasPrefix(prefix) && !$0.hasPrefix("auth:") }
        return matches
            .map { ($0, modDate(at: (root as NSString).appendingPathComponent($0))) }
            .sorted { $0.1 > $1.1 }
    }

    private func modDate(at path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    private func openReadOnly<T>(_ path: String, _ work: (OpaquePointer) -> T) -> T? {
        // WAL mode note: SQLITE_OPEN_READONLY can't write the -shm sidecar, which means a
        // read-only connection may not be able to see rows sitting in the WAL that haven't
        // been checkpointed yet — everything comes back empty. Opening read-write is fine
        // for a second connection (WAL was designed for this), and our code never issues
        // any DML; the `SELECT` statements below are the only thing we do.
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            if let db {
                let err = String(cString: sqlite3_errmsg(db))
                inspectorLog("sqlite open failed (\(path)): \(err)", level: "error")
                sqlite3_close_v2(db)
            } else {
                inspectorLog("sqlite open failed (\(path)): rc=\(rc)", level: "error")
            }
            return nil
        }
        defer { sqlite3_close_v2(db) }
        return work(db)
    }
}
#endif
