import Foundation
import SQLite3

/// Single-file SQLite database. The interface contract between observation and analysis layers.
/// All access is serialized through `queue` — safe to call from any thread.
final class PatinaDatabase {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "patina.db", qos: .utility)
    let path: String

    init() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Patina", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent("patina.db").path
        print("[DB] Opening: \(path)")

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw PatinaError.database("Failed to open: \(msg)")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try createTables()
    }

    deinit {
        sqlite3_close(db)
    }

    private func createTables() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS observations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            app_id TEXT NOT NULL,
            app_name TEXT NOT NULL,
            window_title TEXT,
            element_role TEXT,
            element_title TEXT,
            element_value TEXT,
            element_description TEXT,
            event_type TEXT NOT NULL,
            session_id TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'ax'
        );
        CREATE INDEX IF NOT EXISTS idx_obs_timestamp ON observations(timestamp);
        CREATE INDEX IF NOT EXISTS idx_obs_session ON observations(session_id);
        CREATE INDEX IF NOT EXISTS idx_obs_app ON observations(app_id);

        CREATE TABLE IF NOT EXISTS patterns (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            description TEXT NOT NULL,
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL,
            occurrence_count INTEGER DEFAULT 1,
            observation_ids TEXT NOT NULL,
            status TEXT DEFAULT 'detected',
            llm_confidence REAL
        );
        CREATE INDEX IF NOT EXISTS idx_patterns_status ON patterns(status);

        CREATE TABLE IF NOT EXISTS analysis_batches (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sent_at TEXT NOT NULL,
            received_at TEXT,
            observation_count INTEGER NOT NULL,
            last_observation_id INTEGER,
            prompt_tokens INTEGER,
            completion_tokens INTEGER,
            cost_usd REAL,
            status TEXT DEFAULT 'pending',
            response_json TEXT
        );

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS coverage_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            app_id TEXT NOT NULL,
            app_name TEXT NOT NULL,
            has_element_data INTEGER NOT NULL DEFAULT 0,
            session_id TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_coverage_session ON coverage_log(session_id);
        CREATE INDEX IF NOT EXISTS idx_coverage_app ON coverage_log(app_id);
        """
        try execute(sql)
        try runMigrations()
    }

    private func runMigrations() throws {
        let version = try queue.sync { () -> Int in
            let sql = "PRAGMA user_version"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }

        if version < 2 {
            do {
                try execute("ALTER TABLE analysis_batches ADD COLUMN last_observation_id INTEGER")
            } catch {
                // Column may already exist — idempotent
            }
            try execute("PRAGMA user_version = 2")
            print("[DB] Migrated to user_version 2")
        }

        if version < 3 {
            do {
                try execute("ALTER TABLE patterns ADD COLUMN recommendation TEXT")
            } catch {
                // Column may already exist — idempotent
            }
            try execute("PRAGMA user_version = 3")
            print("[DB] Migrated to user_version 3")
        }
    }

    func insertObservation(_ obs: ObservationRow) throws {
        try queue.sync {
            try _insertObservation(obs)
        }
    }

    private func _insertObservation(_ obs: ObservationRow) throws {
        let sql = """
        INSERT INTO observations (timestamp, app_id, app_name, window_title, element_role,
            element_title, element_value, element_description, event_type, session_id, source)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PatinaError.database("Prepare failed: \(lastError)")
        }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, obs.timestamp)
        bind(stmt, 2, obs.appId)
        bind(stmt, 3, obs.appName)
        bind(stmt, 4, obs.windowTitle)
        bind(stmt, 5, obs.elementRole)
        bind(stmt, 6, obs.elementTitle)
        bind(stmt, 7, obs.elementValue)
        bind(stmt, 8, obs.elementDescription)
        bind(stmt, 9, obs.eventType)
        bind(stmt, 10, obs.sessionId)
        bind(stmt, 11, obs.source)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PatinaError.database("Insert failed: \(lastError)")
        }
    }

    /// Update element_value on the most recent focus_change observation for this session.
    /// Used by departure capture: store the final field value when focus moves away.
    func updateLastElementValue(sessionId: String, value: String) {
        queue.sync {
            let sql = """
            UPDATE observations SET element_value = ?
            WHERE id = (SELECT id FROM observations WHERE session_id = ? AND event_type = 'focus_change' ORDER BY id DESC LIMIT 1)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, value)
            bind(stmt, 2, sessionId)
            sqlite3_step(stmt)
        }
    }

    func observationsForSession(_ sessionId: String) throws -> [ObservationRow] {
        try queue.sync {
            let sql = "SELECT * FROM observations WHERE session_id = ? ORDER BY timestamp ASC"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, sessionId)

            var rows: [ObservationRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readObservation(stmt))
            }
            return rows
        }
    }

    func observationCount() throws -> Int {
        try queue.sync {
            let sql = "SELECT COUNT(*) FROM observations"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    func todayObservations() throws -> [ObservationRow] {
        try queue.sync {
            let today = ISO8601Formatter.dateOnly(Date())
            let sql = "SELECT * FROM observations WHERE timestamp >= ? ORDER BY timestamp ASC"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, today)

            var rows: [ObservationRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readObservation(stmt))
            }
            return rows
        }
    }

    // MARK: - Coverage logging

    func insertCoverageLog(appId: String, appName: String, hasElementData: Bool,
                           timestamp: String, sessionId: String) throws {
        try queue.sync {
            let sql = "INSERT INTO coverage_log (timestamp, app_id, app_name, has_element_data, session_id) VALUES (?, ?, ?, ?, ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, timestamp)
            bind(stmt, 2, appId)
            bind(stmt, 3, appName)
            sqlite3_bind_int(stmt, 4, hasElementData ? 1 : 0)
            bind(stmt, 5, sessionId)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw PatinaError.database("Insert coverage failed: \(lastError)")
            }
        }
    }

    /// Returns per-app coverage stats for the current session
    func coverageStats(sessionId: String) throws -> [AppCoverage] {
        try queue.sync {
            let sql = """
            SELECT app_id, app_name,
                   COUNT(*) as total_polls,
                   SUM(has_element_data) as polls_with_data
            FROM coverage_log
            WHERE session_id = ?
            GROUP BY app_id
            ORDER BY total_polls DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, sessionId)

            var rows: [AppCoverage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(AppCoverage(
                    appId: col(stmt, 0) ?? "",
                    appName: col(stmt, 1) ?? "",
                    totalPolls: Int(sqlite3_column_int64(stmt, 2)),
                    pollsWithData: Int(sqlite3_column_int64(stmt, 3))
                ))
            }
            return rows
        }
    }

    // MARK: - Settings

    func getSetting(_ key: String) -> String? {
        queue.sync {
            let sql = "SELECT value FROM settings WHERE key = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, key)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return col(stmt, 0)
        }
    }

    func setSetting(_ key: String, _ value: String) {
        queue.sync {
            let sql = "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, key)
            bind(stmt, 2, value)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Analysis batches

    func insertBatch(observationCount: Int, lastObservationId: Int) throws -> Int64 {
        try queue.sync {
            let sql = """
            INSERT INTO analysis_batches (sent_at, observation_count, last_observation_id, status)
            VALUES (?, ?, ?, 'pending')
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, ISO8601Formatter.now())
            sqlite3_bind_int64(stmt, 2, Int64(observationCount))
            sqlite3_bind_int64(stmt, 3, Int64(lastObservationId))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw PatinaError.database("Insert batch failed: \(lastError)")
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func updateBatch(id: Int64, status: String, receivedAt: String?,
                     promptTokens: Int?, completionTokens: Int?,
                     costUSD: Double?, responseJSON: String?) throws {
        try queue.sync {
            let sql = """
            UPDATE analysis_batches
            SET status = ?, received_at = ?, prompt_tokens = ?,
                completion_tokens = ?, cost_usd = ?, response_json = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, status)
            bind(stmt, 2, receivedAt)
            if let t = promptTokens { sqlite3_bind_int64(stmt, 3, Int64(t)) } else { sqlite3_bind_null(stmt, 3) }
            if let t = completionTokens { sqlite3_bind_int64(stmt, 4, Int64(t)) } else { sqlite3_bind_null(stmt, 4) }
            if let c = costUSD { sqlite3_bind_double(stmt, 5, c) } else { sqlite3_bind_null(stmt, 5) }
            bind(stmt, 6, responseJSON)
            sqlite3_bind_int64(stmt, 7, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw PatinaError.database("Update batch failed: \(lastError)")
            }
        }
    }

    /// Observations not yet analyzed. Uses observation rowid as cutoff (not timestamp) to prevent gaps.
    func unanalyzedObservations(limit: Int = 50) throws -> [ObservationRow] {
        try queue.sync {
            let cutoffSQL = "SELECT MAX(last_observation_id) FROM analysis_batches WHERE status = 'completed'"
            var cutoffStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, cutoffSQL, -1, &cutoffStmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(cutoffStmt) }

            var cutoffId: Int64? = nil
            if sqlite3_step(cutoffStmt) == SQLITE_ROW && sqlite3_column_type(cutoffStmt, 0) != SQLITE_NULL {
                cutoffId = sqlite3_column_int64(cutoffStmt, 0)
            }

            let sql: String
            if cutoffId != nil {
                sql = "SELECT * FROM observations WHERE id > ? ORDER BY id ASC LIMIT \(limit)"
            } else {
                sql = "SELECT * FROM observations ORDER BY id ASC LIMIT \(limit)"
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            if let cutoffId = cutoffId {
                sqlite3_bind_int64(stmt, 1, cutoffId)
            }

            var rows: [ObservationRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readObservation(stmt))
            }
            return rows
        }
    }

    // MARK: - Patterns

    /// Clamp string length and strip control chars (OWASP LLM05 defense)
    private func sanitizeLLMOutput(_ text: String?, maxLen: Int) -> String? {
        guard let t = text else { return nil }
        let cleaned = String(t.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" })
        return String(cleaned.prefix(maxLen))
    }

    func insertPattern(name: String?, description: String, recommendation: String? = nil,
                       observationIds: [Int], confidence: Double?) throws {
        try queue.sync {
            let sql = """
            INSERT INTO patterns (name, description, recommendation, first_seen, last_seen, observation_ids, llm_confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            let now = ISO8601Formatter.now()
            let idsString = observationIds.map { String($0) }.joined(separator: ",")
            bind(stmt, 1, sanitizeLLMOutput(name, maxLen: 80))
            bind(stmt, 2, sanitizeLLMOutput(description, maxLen: 500) ?? "")
            bind(stmt, 3, sanitizeLLMOutput(recommendation, maxLen: 300))
            bind(stmt, 4, now)
            bind(stmt, 5, now)
            bind(stmt, 6, idsString)
            if let c = confidence { sqlite3_bind_double(stmt, 7, c) } else { sqlite3_bind_null(stmt, 7) }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw PatinaError.database("Insert pattern failed: \(lastError)")
            }
        }
    }

    func allPatterns() throws -> [PatternRow] {
        try queue.sync {
            let sql = "SELECT id, name, description, recommendation, llm_confidence, observation_ids, status FROM patterns ORDER BY id DESC"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PatinaError.database("Prepare failed: \(lastError)")
            }
            defer { sqlite3_finalize(stmt) }
            var rows: [PatternRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(stmt, 0))
                let name = col(stmt, 1)
                let desc = col(stmt, 2) ?? ""
                let recommendation = col(stmt, 3)
                let conf: Double? = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_double(stmt, 4) : nil
                let obsIds = col(stmt, 5) ?? ""
                let status = col(stmt, 6) ?? "detected"
                rows.append(PatternRow(id: id, name: name, description: desc, recommendation: recommendation, confidence: conf, observationIds: obsIds, status: status))
            }
            return rows
        }
    }

    // MARK: - Log viewer queries

    func queryObservations(search: String? = nil, since: Date? = nil, appName: String? = nil,
                           limit: Int = 500, offset: Int = 0) -> [ObservationRow] {
        queue.sync {
            var clauses: [String] = []
            var binds: [String] = []

            if let search = search, !search.isEmpty {
                clauses.append("(app_name LIKE ? OR window_title LIKE ? OR element_title LIKE ? OR element_value LIKE ?)")
                let term = "%\(search)%"
                binds.append(contentsOf: [term, term, term, term])
            }
            if let since = since {
                clauses.append("timestamp >= ?")
                binds.append(ISO8601Formatter.string(from: since))
            }
            if let appName = appName, !appName.isEmpty {
                clauses.append("app_name = ?")
                binds.append(appName)
            }

            var sql = "SELECT * FROM observations"
            if !clauses.isEmpty {
                sql += " WHERE " + clauses.joined(separator: " AND ")
            }
            sql += " ORDER BY id DESC LIMIT \(limit) OFFSET \(offset)"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            for (i, val) in binds.enumerated() {
                bind(stmt, Int32(i + 1), val)
            }

            var rows: [ObservationRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readObservation(stmt))
            }
            return rows
        }
    }

    func queryObservationCount(search: String? = nil, since: Date? = nil, appName: String? = nil) -> Int {
        queue.sync {
            var clauses: [String] = []
            var binds: [String] = []

            if let search = search, !search.isEmpty {
                clauses.append("(app_name LIKE ? OR window_title LIKE ? OR element_title LIKE ? OR element_value LIKE ?)")
                let term = "%\(search)%"
                binds.append(contentsOf: [term, term, term, term])
            }
            if let since = since {
                clauses.append("timestamp >= ?")
                binds.append(ISO8601Formatter.string(from: since))
            }
            if let appName = appName, !appName.isEmpty {
                clauses.append("app_name = ?")
                binds.append(appName)
            }

            var sql = "SELECT COUNT(*) FROM observations"
            if !clauses.isEmpty {
                sql += " WHERE " + clauses.joined(separator: " AND ")
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }

            for (i, val) in binds.enumerated() {
                bind(stmt, Int32(i + 1), val)
            }

            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    func deleteObservations(ids: [Int]) {
        queue.sync {
            // Batch in groups of 500 to avoid SQLite variable limit
            let batchSize = 500
            for start in stride(from: 0, to: ids.count, by: batchSize) {
                let end = min(start + batchSize, ids.count)
                let batch = Array(ids[start..<end])
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                let sql = "DELETE FROM observations WHERE id IN (\(placeholders))"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(stmt) }
                for (i, id) in batch.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(i + 1), Int64(id))
                }
                sqlite3_step(stmt)
            }
        }
    }

    func deleteAllObservations() {
        queue.sync {
            var err: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, "DELETE FROM observations", nil, nil, &err)
            if let err = err { sqlite3_free(err) }
        }
    }

    func distinctAppNames() -> [String] {
        queue.sync {
            let sql = "SELECT DISTINCT app_name FROM observations ORDER BY app_name"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var names: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = col(stmt, 0) {
                    names.append(name)
                }
            }
            return names
        }
    }

    // MARK: - Maintenance

    func pruneCoverageLog(olderThanDays: Int = 3, maxRows: Int = 100_000) {
        queue.sync {
            // Time-based pruning
            let cal = Calendar(identifier: .gregorian)
            if let cutoff = cal.date(byAdding: .day, value: -olderThanDays, to: Date()) {
                let cutoffStr = ISO8601Formatter.string(from: cutoff)
                let sql = "DELETE FROM coverage_log WHERE timestamp < ?"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(stmt) }
                    bind(stmt, 1, cutoffStr)
                    if sqlite3_step(stmt) == SQLITE_DONE {
                        let deleted = sqlite3_changes(db)
                        if deleted > 0 {
                            print("[DB] Pruned \(deleted) coverage_log rows older than \(olderThanDays) days")
                        }
                    }
                }
            }

            // Row-count cap: keep only the most recent maxRows
            let countSQL = "SELECT COUNT(*) FROM coverage_log"
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(countStmt) }
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    let count = Int(sqlite3_column_int64(countStmt, 0))
                    if count > maxRows {
                        let excess = count - maxRows
                        let delSQL = "DELETE FROM coverage_log WHERE id IN (SELECT id FROM coverage_log ORDER BY id ASC LIMIT \(excess))"
                        var err: UnsafeMutablePointer<CChar>?
                        sqlite3_exec(db, delSQL, nil, nil, &err)
                        if let err = err { sqlite3_free(err) }
                        else { print("[DB] Pruned \(excess) excess coverage_log rows (cap: \(maxRows))") }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw PatinaError.database(msg)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ val: String?) {
        if let val = val {
            sqlite3_bind_text(stmt, idx, (val as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func readObservation(_ stmt: OpaquePointer?) -> ObservationRow {
        ObservationRow(
            id: Int(sqlite3_column_int64(stmt, 0)),
            timestamp: col(stmt, 1) ?? "",
            appId: col(stmt, 2) ?? "",
            appName: col(stmt, 3) ?? "",
            windowTitle: col(stmt, 4),
            elementRole: col(stmt, 5),
            elementTitle: col(stmt, 6),
            elementValue: col(stmt, 7),
            elementDescription: col(stmt, 8),
            eventType: col(stmt, 9) ?? "",
            sessionId: col(stmt, 10) ?? "",
            source: col(stmt, 11) ?? "ax"
        )
    }

    private func col(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: ptr)
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(db))
    }
}

// MARK: - Types

struct ObservationRow {
    let id: Int?
    let timestamp: String
    let appId: String
    let appName: String
    let windowTitle: String?
    let elementRole: String?
    let elementTitle: String?
    let elementValue: String?
    let elementDescription: String?
    let eventType: String
    let sessionId: String
    let source: String

    init(
        id: Int? = nil,
        timestamp: String,
        appId: String,
        appName: String,
        windowTitle: String? = nil,
        elementRole: String? = nil,
        elementTitle: String? = nil,
        elementValue: String? = nil,
        elementDescription: String? = nil,
        eventType: String,
        sessionId: String,
        source: String = "ax"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appId = appId
        self.appName = appName
        self.windowTitle = windowTitle
        self.elementRole = elementRole
        self.elementTitle = elementTitle
        self.elementValue = elementValue
        self.elementDescription = elementDescription
        self.eventType = eventType
        self.sessionId = sessionId
        self.source = source
    }
}

struct AppCoverage {
    let appId: String
    let appName: String
    let totalPolls: Int
    let pollsWithData: Int
    var coveragePercent: Double {
        totalPolls == 0 ? 0 : Double(pollsWithData) / Double(totalPolls) * 100.0
    }
}

struct PatternRow {
    let id: Int
    let name: String?
    let description: String
    let recommendation: String?
    let confidence: Double?
    let observationIds: String
    let status: String
}

enum PatinaError: Error, LocalizedError {
    case database(String)
    case observation(String)
    case analysis(String)

    var errorDescription: String? {
        switch self {
        case .database(let msg): return "Database: \(msg)"
        case .observation(let msg): return "Observation: \(msg)"
        case .analysis(let msg): return "Analysis: \(msg)"
        }
    }
}

enum ISO8601Formatter {
    private static let full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func now() -> String { full.string(from: Date()) }
    static func string(from date: Date) -> String { full.string(from: date) }
    static func date(from string: String) -> Date? { full.date(from: string) }

    static func dateOnly(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02dT00:00:00Z", comps.year!, comps.month!, comps.day!)
    }

    /// Returns "YYYY-MM-DD" for today in UTC. Used for daily counters.
    static func dayString() -> String {
        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
    }
}
