import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Thin read-only access to `~/.shannon/agent_hub.db` written by `hub/shannon_gate.py`.
///
/// This is the **only** source of real agent telemetry the pill has: a row in
/// `agents` means a process actually spoke to the gate over `/tmp/shannon.sock`.
/// Everything else the pill knows (pets, `agents.json`) is derived from which
/// macOS app happened to be frontmost when the user pressed ⌘D — useful as a
/// label, worthless as proof that an agent is working. The reader therefore
/// hands back an explicit `presence` so the merge layer can keep the two kinds
/// of evidence apart instead of letting a foreground observation masquerade as
/// live telemetry.
public enum GateDBReader {

    // MARK: - Combined snapshot

    /// Everything the pill needs from the hub DB, read through **one** SQLite
    /// connection. The previous code opened (and closed) the database once per
    /// query, three times per 1.5 s poll; this opens it once.
    public struct Snapshot: Sendable, Equatable {
        /// True when the database existed and could be opened read-only.
        public var available: Bool
        public var agents: [AgentActivitySnapshot]
        /// Approvals a human can still act on.
        public var pendingAsks: [PendingAsk]
        /// Rows still marked `pending` whose caller has demonstrably gone away
        /// (the agent disconnected after asking) or that aged out. Kept
        /// separate so the menu bar stops pulsing amber forever, without
        /// silently discarding the information.
        public var staleAsks: [PendingAsk]
        /// Real `agent_activity` rows, newest first.
        public var activity: [ActivityEvent]

        public init(
            available: Bool = false,
            agents: [AgentActivitySnapshot] = [],
            pendingAsks: [PendingAsk] = [],
            staleAsks: [PendingAsk] = [],
            activity: [ActivityEvent] = []
        ) {
            self.available = available
            self.agents = agents
            self.pendingAsks = pendingAsks
            self.staleAsks = staleAsks
            self.activity = activity
        }
    }

    /// Read agents, open approvals and the activity feed in a single pass.
    ///
    /// - Parameters:
    ///   - askMaxAge: backstop age after which a still-`pending` row is treated
    ///     as stale even if we cannot prove the caller left.
    public static func readSnapshot(
        path: String,
        now: Date = Date(),
        askMaxAge: TimeInterval = 6 * 3600,
        askLimit: Int = 5,
        activityLimit: Int = 8
    ) -> Snapshot {
        #if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return Snapshot()
        }
        defer { sqlite3_close(db) }
        // Never block the UI on a writer holding the DB.
        sqlite3_busy_timeout(db, 50)

        let asks = pendingAsks(db, limit: askLimit)
        let live = asks.filter { !$0.isOrphaned && now.timeIntervalSince($0.createdAt) <= askMaxAge }
        let stale = asks.filter { $0.isOrphaned || now.timeIntervalSince($0.createdAt) > askMaxAge }
        return Snapshot(
            available: true,
            agents: agentRows(db),
            pendingAsks: live,
            staleAsks: stale,
            activity: activityRows(db, limit: activityLimit)
        )
        #else
        return Snapshot()
        #endif
    }

    // MARK: - Agents

    /// Read agent rows. Returns [] if the DB is missing, locked, or schema-old.
    public static func readAgents(path: String) -> [AgentActivitySnapshot] {
        #if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        return agentRows(db)
        #else
        return []
        #endif
    }

    #if canImport(SQLite3)
    private static func agentRows(_ db: OpaquePointer) -> [AgentActivitySnapshot] {
        // Preferred (current hub schema).
        //
        // `connected` is derived from `disconnected_at`, which the old reader
        // ignored entirely — that is why agents that hung up two days ago still
        // rendered as current. The gate NULLs the column on reconnect, so a
        // non-NULL value newer than `last_seen_ns` means "definitely gone".
        //
        // `message_count` on the row is unreliable (the gate only bumps it on
        // some paths — grok_build showed 1 against 5 real rows), so the real
        // count from `agent_messages` wins when it is higher.
        let sqlNS = """
            SELECT a.agent_id, a.status,
                   CAST(a.last_seen_ns / 1000000000.0 AS REAL) AS last_seen,
                   COALESCE(a.entropy_score, 0),
                   COALESCE(a.task_summary, ''),
                   MAX(COALESCE(a.message_count, 0),
                       (SELECT COUNT(*) FROM agent_messages m WHERE m.agent_id = a.agent_id)),
                   CASE WHEN a.disconnected_at IS NULL
                          OR a.disconnected_at < a.last_seen_ns THEN 1 ELSE 0 END AS connected
            FROM agents a;
            """
        if let rows = query(db, sqlNS) { return rows }

        // Legacy seconds-based schema without `disconnected_at`: we cannot prove
        // the connection state, so report `.observed` (unproven) rather than
        // claiming the agent is live.
        let sqlLegacy = """
            SELECT agent_id, status, last_seen,
                   COALESCE(entropy_score, 0),
                   COALESCE(task_summary, ''),
                   0, -1
            FROM agents;
            """
        return query(db, sqlLegacy) ?? []
    }

    private static func query(_ db: OpaquePointer, _ sql: String) -> [AgentActivitySnapshot]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var out: [AgentActivitySnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = string(stmt, 0)
            guard !id.isEmpty else { continue }
            let statusRaw = string(stmt, 1)
            let lastSeen = sqlite3_column_double(stmt, 2)
            // entropy available at col 3 — owned by the entropy readout, not us.
            _ = sqlite3_column_double(stmt, 3)
            let task = string(stmt, 4)
            let msgCount = Int(sqlite3_column_int(stmt, 5))
            let connectedFlag = Int(sqlite3_column_int(stmt, 6))
            let presence: AgentPresence = connectedFlag == 1
                ? .live
                : (connectedFlag == 0 ? .offline : .observed)

            let cleanTask = AgentActivitySnapshot.looksLikeSecretOrJunk(task)
                ? ""
                : AgentActivitySnapshot.shorten(task, max: 120)
            // A disconnected agent is not doing anything, whatever the last
            // status write said. Truth beats the stored string.
            let status = presence == .offline ? AgentRunStatus.idle : AgentRunStatus(raw: statusRaw)
            out.append(AgentActivitySnapshot(
                id: id,
                displayName: id.replacingOccurrences(of: "_", with: " ").capitalized,
                status: status,
                lastTask: cleanTask,
                source: "gate",
                updatedAt: lastSeen > 0 ? Date(timeIntervalSince1970: lastSeen) : .distantPast,
                resumable: status.isBusy,
                historyCount: msgCount,
                presence: presence
            ))
        }
        return out
    }
    #endif

    // MARK: - Approvals

    /// A human approval the gate is waiting on.
    ///
    /// Source: `agent_interactions` rows with status = 'pending', the same table
    /// the hub popup treats as authoritative. `interactionId` is the gate's own
    /// id — it must be echoed back verbatim to resolve the ask.
    public struct PendingAsk: Identifiable, Equatable, Sendable {
        public var id: String { interactionId }
        public let interactionId: String
        public let agentId: String
        public let prompt: String
        /// When the agent asked. Drives both the "waiting 3m" copy and the
        /// staleness backstop.
        public let createdAt: Date
        /// True when the asking agent disconnected *after* creating the row —
        /// nobody is on the other end any more, so answering it is theatre.
        public let isOrphaned: Bool

        public init(
            interactionId: String,
            agentId: String,
            prompt: String,
            createdAt: Date = .distantPast,
            isOrphaned: Bool = false
        ) {
            self.interactionId = interactionId
            self.agentId = agentId
            self.prompt = prompt
            self.createdAt = createdAt
            self.isOrphaned = isOrphaned
        }

        /// "12s" / "4m" / "2d" since the agent asked.
        public var waitingFor: String { AgentActivitySnapshot.age(since: createdAt) }
    }

    /// Read open approvals a human can still act on, newest first.
    ///
    /// Rows whose caller has gone away are filtered out — see
    /// `readSnapshot(...).staleAsks` if you need them. Returns [] when the
    /// table is absent, which is the normal case on a gate that has never
    /// asked anything.
    public static func readPendingAsks(
        path: String,
        limit: Int = 5,
        now: Date = Date(),
        maxAge: TimeInterval = 6 * 3600
    ) -> [PendingAsk] {
        readSnapshot(path: path, now: now, askMaxAge: maxAge, askLimit: limit, activityLimit: 0)
            .pendingAsks
    }

    #if canImport(SQLite3)
    private static func pendingAsks(_ db: OpaquePointer, limit: Int) -> [PendingAsk] {
        guard limit > 0 else { return [] }
        // LEFT JOIN so an ask from an agent with no `agents` row is *not*
        // declared orphaned — we only drop what we can prove is dead.
        let sql = """
            SELECT i.interaction_id, i.agent_id, i.prompt,
                   CAST(i.created_at_ns / 1000000000.0 AS REAL),
                   CASE WHEN a.disconnected_at IS NOT NULL
                         AND a.disconnected_at > i.created_at_ns THEN 1 ELSE 0 END
            FROM agent_interactions i
            LEFT JOIN agents a ON a.agent_id = i.agent_id
            WHERE i.status = 'pending'
            ORDER BY i.created_at_ns DESC
            LIMIT \(max(1, limit));
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var out: [PendingAsk] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let iid = string(stmt, 0)
            guard !iid.isEmpty else { continue }
            let created = sqlite3_column_double(stmt, 3)
            out.append(PendingAsk(
                interactionId: iid,
                agentId: string(stmt, 1),
                prompt: AgentActivitySnapshot.shorten(string(stmt, 2), max: 160),
                createdAt: created > 0 ? Date(timeIntervalSince1970: created) : .distantPast,
                isOrphaned: sqlite3_column_int(stmt, 4) == 1
            ))
        }
        return out
    }
    #endif

    // MARK: - Activity feed

    /// One row of `agent_activity` — a thing an agent actually did.
    ///
    /// The popover used to render the *agent list* under an "Activity" heading,
    /// so "Terminal: Working in Ghostty" appeared as if it were an event. These
    /// are the real events, correctly attributed and ordered.
    public struct ActivityEvent: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let agentId: String
        public let at: Date
        /// `tool_call` | `status` | `approval_needed` | `approval_response` | …
        public let type: String
        public let label: String
        public let output: String

        public init(
            id: Int64, agentId: String, at: Date,
            type: String, label: String, output: String
        ) {
            self.id = id
            self.agentId = agentId
            self.at = at
            self.type = type
            self.label = label
            self.output = output
        }

        public var relativeAge: String { AgentActivitySnapshot.age(since: at) }

        /// One-line summary safe to drop straight into the UI.
        public var line: String {
            let l = AgentActivitySnapshot.shorten(label, max: 60)
            return l.isEmpty ? type : l
        }
    }

    /// Newest `agent_activity` rows. [] when the table or DB is absent.
    public static func readRecentActivity(path: String, limit: Int = 8) -> [ActivityEvent] {
        readSnapshot(path: path, askLimit: 1, activityLimit: limit).activity
    }

    #if canImport(SQLite3)
    private static func activityRows(_ db: OpaquePointer, limit: Int) -> [ActivityEvent] {
        guard limit > 0 else { return [] }
        let sql = """
            SELECT id, agent_id,
                   CAST(event_at_ns / 1000000000.0 AS REAL),
                   event_type, event_label, COALESCE(event_output, '')
            FROM agent_activity
            ORDER BY event_at_ns DESC, id DESC
            LIMIT \(max(1, limit));
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var out: [ActivityEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_double(stmt, 2)
            out.append(ActivityEvent(
                id: sqlite3_column_int64(stmt, 0),
                agentId: string(stmt, 1),
                at: ts > 0 ? Date(timeIntervalSince1970: ts) : .distantPast,
                type: string(stmt, 3),
                label: AgentActivitySnapshot.shorten(string(stmt, 4), max: 120),
                output: AgentActivitySnapshot.shorten(string(stmt, 5), max: 120)
            ))
        }
        return out
    }

    private static func string(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
    #endif
}
