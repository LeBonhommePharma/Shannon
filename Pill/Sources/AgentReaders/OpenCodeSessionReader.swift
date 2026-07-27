import Foundation
import PillCore
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - OpenCode session reader (ENH-027 / parity G2)

/// Reads OpenCode sessions from the local SQLite store
/// (`~/.local/share/opencode/opencode.db`).
///
/// OpenCode is already a Shannon handrail agent (`opencode` in
/// `hub/agent_identity.py`). This reader surfaces on-disk sessions for the
/// Pulled sessions panel — **fail-closed**: missing/unreadable DB → `[]`.
/// Never invents tokens (0 defaults stay `nil`) or gate Approve capability.
public struct OpenCodeSessionReader: SessionProviding {
    public let providerId = "opencode_artifacts"
    /// Explicit database path(s). First readable wins; empty list → default roots.
    public var databasePaths: [URL]
    public var maxSessions: Int
    /// Optional override for branch resolution (tests inject; production uses git).
    public var resolveBranch: @Sendable (String?) -> String?

    public init(
        databasePaths: [URL]? = nil,
        maxSessions: Int = 24,
        resolveBranch: (@Sendable (String?) -> String?)? = nil
    ) {
        if let databasePaths {
            self.databasePaths = databasePaths
        } else {
            self.databasePaths = Self.defaultDatabasePaths()
        }
        self.maxSessions = max(0, maxSessions)
        self.resolveBranch = resolveBranch ?? { GitBranchProbe.branch(for: $0) }
    }

    /// Well-known OpenCode DB locations + optional `SHANNON_OPENCODE_DB` override.
    public static func defaultDatabasePaths(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var paths: [URL] = []
        if let env = environment["SHANNON_OPENCODE_DB"], !env.isEmpty {
            paths.append(URL(fileURLWithPath: env))
        }
        // XDG data home (Linux + many macOS installs).
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            paths.append(
                URL(fileURLWithPath: xdg, isDirectory: true)
                    .appendingPathComponent("opencode/opencode.db")
            )
        }
        paths.append(
            home.appendingPathComponent(".local/share/opencode/opencode.db")
        )
        // Config sibling some installs use for the data dir.
        paths.append(
            home.appendingPathComponent(".opencode/opencode.db")
        )
        return paths
    }

    public func fetchSessions(now: Date) -> [AgentSession] {
        Self.readSessions(
            databasePaths: databasePaths,
            now: now,
            maxSessions: maxSessions,
            resolveBranch: resolveBranch
        )
    }

    public static func readSessions(
        databasePaths: [URL],
        now: Date = Date(),
        maxSessions: Int = 24,
        resolveBranch: (@Sendable (String?) -> String?)? = nil
    ) -> [AgentSession] {
        let branchOf: @Sendable (String?) -> String? =
            resolveBranch ?? { GitBranchProbe.branch(for: $0) }
        for path in databasePaths {
            let rows = loadRows(from: path, maxSessions: max(maxSessions, 1) * 2)
            guard !rows.isEmpty else { continue }
            var sessions: [AgentSession] = []
            var branchCache: [String: String?] = [:]
            for row in rows {
                var s = sessionFromRow(row, now: now)
                if let cwd = s.cwd {
                    if let cached = branchCache[cwd] {
                        s.branch = cached
                    } else {
                        let b = branchOf(cwd)
                        branchCache[cwd] = b
                        s.branch = b
                    }
                }
                sessions.append(s)
            }
            sessions.sort { $0.updatedAt > $1.updatedAt }
            if sessions.count > maxSessions {
                return Array(sessions.prefix(maxSessions))
            }
            return sessions
        }
        return []
    }

    // MARK: - Pure row → session

    /// One session table row (testable without SQLite).
    public struct SessionRow: Sendable, Equatable {
        public var id: String
        public var title: String
        public var directory: String
        public var modelRaw: String?
        public var tokensInput: Int
        public var tokensOutput: Int
        /// Epoch ms (OpenCode schema) or seconds if small.
        public var timeUpdated: Int64
        public var timeCreated: Int64?
        public var timeArchived: Int64?
        public var sourcePath: String?

        public init(
            id: String,
            title: String,
            directory: String,
            modelRaw: String? = nil,
            tokensInput: Int = 0,
            tokensOutput: Int = 0,
            timeUpdated: Int64,
            timeCreated: Int64? = nil,
            timeArchived: Int64? = nil,
            sourcePath: String? = nil
        ) {
            self.id = id
            self.title = title
            self.directory = directory
            self.modelRaw = modelRaw
            self.tokensInput = tokensInput
            self.tokensOutput = tokensOutput
            self.timeUpdated = timeUpdated
            self.timeCreated = timeCreated
            self.timeArchived = timeArchived
            self.sourcePath = sourcePath
        }
    }

    /// Map a session row to `AgentSession`. Skips empty ids; archived rows still
    /// surface as idle artifacts (caller may filter). Tokens: only when > 0.
    public static func sessionFromRow(_ row: SessionRow, now: Date = Date()) -> AgentSession {
        let sessionId = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = row.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwdOrNil = cwd.isEmpty ? nil : cwd
        let project = cwdOrNil.map { ($0 as NSString).lastPathComponent }
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = title.isEmpty ? nil : title
        let model = parseModelLabel(row.modelRaw)
        let updated = dateFromEpoch(row.timeUpdated) ?? now
        let started = row.timeCreated.flatMap { dateFromEpoch($0) }
        let archived = row.timeArchived != nil
        // Observational only — no gate Approve path from the DB alone.
        let status: AgentRunStatus = archived ? .idle : .idle
        let stateLabel = archived ? "archived" : "artifact"
        // Fail-closed tokens: schema default 0 is not a measurement.
        let tokensIn: Int? = row.tokensInput > 0 ? row.tokensInput : nil
        let tokensOut: Int? = row.tokensOutput > 0 ? row.tokensOutput : nil

        return AgentSession(
            id: "opencode:\(sessionId.isEmpty ? "unknown" : sessionId)",
            agentId: "opencode",
            displayName: "OpenCode",
            presence: .observed,
            status: status,
            sourceKind: .artifact,
            updatedAt: updated,
            project: project,
            cwd: cwdOrNil,
            stateLabel: stateLabel,
            lastTask: task.map { AgentActivitySnapshot.shorten($0, max: 120) },
            model: model,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            sourcePath: row.sourcePath,
            startedAt: started,
            activitySummary: task.map { AgentActivitySnapshot.shorten($0, max: 120) }
        )
    }

    /// Model column is either a plain id or JSON `{"id":"…","providerID":"…"}`.
    public static func parseModelLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let id = obj["id"] as? String, !id.isEmpty { return id }
            if let mid = obj["modelID"] as? String, !mid.isEmpty { return mid }
            if let model = obj["model"] as? String, !model.isEmpty { return model }
        }
        return trimmed
    }

    public static func dateFromEpoch(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let d = Double(value)
        // ms (OpenCode) vs seconds
        if d > 1_000_000_000_000 { return Date(timeIntervalSince1970: d / 1000) }
        if d > 1_000_000_000 { return Date(timeIntervalSince1970: d) }
        return nil
    }

    // MARK: - SQLite load

    /// Load session rows from a DB file. Missing/locked/wrong schema → `[]`.
    public static func loadRows(from databaseURL: URL, maxSessions: Int = 48) -> [SessionRow] {
        #if canImport(SQLite3)
        let path = databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)

        // Prefer full column set; fall back if older schema lacks token cols.
        let queries = [
            """
            SELECT id, title, directory, model,
                   tokens_input, tokens_output,
                   time_updated, time_created, time_archived
            FROM session
            WHERE id IS NOT NULL AND id != ''
            ORDER BY time_updated DESC
            LIMIT \(max(1, maxSessions));
            """,
            """
            SELECT id, title, directory, model,
                   0, 0,
                   time_updated, time_created, NULL
            FROM session
            WHERE id IS NOT NULL AND id != ''
            ORDER BY time_updated DESC
            LIMIT \(max(1, maxSessions));
            """,
        ]

        for sql in queries {
            if let rows = queryRows(db, sql: sql, sourcePath: path) {
                return rows
            }
        }
        return []
        #else
        return []
        #endif
    }

    #if canImport(SQLite3)
    private static func queryRows(
        _ db: OpaquePointer,
        sql: String,
        sourcePath: String
    ) -> [SessionRow]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var out: [SessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnString(stmt, 0)
            guard !id.isEmpty else { continue }
            let title = columnString(stmt, 1)
            let directory = columnString(stmt, 2)
            let model = columnString(stmt, 3)
            let tokensIn = Int(sqlite3_column_int(stmt, 4))
            let tokensOut = Int(sqlite3_column_int(stmt, 5))
            let timeUpdated = sqlite3_column_int64(stmt, 6)
            let timeCreated: Int64? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                ? nil : sqlite3_column_int64(stmt, 7)
            let timeArchived: Int64? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil : sqlite3_column_int64(stmt, 8)
            out.append(SessionRow(
                id: id,
                title: title,
                directory: directory,
                modelRaw: model.isEmpty ? nil : model,
                tokensInput: tokensIn,
                tokensOutput: tokensOut,
                timeUpdated: timeUpdated,
                timeCreated: timeCreated,
                timeArchived: timeArchived,
                sourcePath: sourcePath
            ))
        }
        return out
    }

    private static func columnString(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
    #endif
}
