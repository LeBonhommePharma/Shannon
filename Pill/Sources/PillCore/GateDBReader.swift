import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - Entropy measurement clock (pure)

/// Resolves when a gate `entropy_score` was *substantively* written.
///
/// Heartbeats still advance `last_seen_ns` without touching the score. If we
/// aged H from `last_seen`, a frozen ~2.38 bit attach-status score would look
/// live forever. When the schema has `entropy_updated_ns`, only that clock is
/// usable; a zero/DEFAULT value means "no honest measurement time" → refuse.
public enum GateEntropyClock {
    /// - Parameter hasEntropyUpdatedColumn: true when SELECT included col 8.
    /// - Parameter entropyUpdatedSeconds: unix seconds (0 = never written).
    /// - Parameter lastSeenSeconds: only used for pre-column legacy schemas.
    /// - Returns: unix seconds for `measuredAt`, or `nil` to refuse the score.
    public static func measuredAtSeconds(
        hasEntropyUpdatedColumn: Bool,
        entropyUpdatedSeconds: TimeInterval,
        lastSeenSeconds: TimeInterval
    ) -> TimeInterval? {
        if hasEntropyUpdatedColumn {
            return entropyUpdatedSeconds > 0 ? entropyUpdatedSeconds : nil
        }
        return lastSeenSeconds > 0 ? lastSeenSeconds : nil
    }
}

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
        /// Gate-computed entropy per agent — the only *measured* H the pill has
        /// access to when no detector socket is attached.
        ///
        /// Each element carries its own agent id, presence and measurement time,
        /// so a 40-minute-old value cannot be presented as a current one. Rows
        /// the gate has never scored produce **no** element rather than a zero;
        /// see `entropyMeasurement(_:at:now:policy:)`.
        public var agentEntropy: [EntropyMeasurement]

        public init(
            available: Bool = false,
            agents: [AgentActivitySnapshot] = [],
            pendingAsks: [PendingAsk] = [],
            staleAsks: [PendingAsk] = [],
            activity: [ActivityEvent] = [],
            agentEntropy: [EntropyMeasurement] = []
        ) {
            self.available = available
            self.agents = agents
            self.pendingAsks = pendingAsks
            self.staleAsks = staleAsks
            self.activity = activity
            self.agentEntropy = agentEntropy
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
        activityLimit: Int = 8,
        entropyPolicy: EntropyPolicy = .current
    ) -> Snapshot {
        #if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return Snapshot()
        }
        defer { sqlite3_close(db) }
        // Never block the UI on a writer holding the DB.
        sqlite3_busy_timeout(db, 50)

        // Fetch a *superset* ordered actionable-first, then apply `askLimit` to
        // what survives the orphan/age filter. Applying the SQL LIMIT to raw
        // rows meant five abandoned approvals could hide every answerable one
        // (the user then had no way to see, let alone answer, a live ask).
        let asks = pendingAsks(db, limit: askLimit, staleBeforeNs: staleCutoffNs(now: now, maxAge: askMaxAge))
        let keep = max(0, askLimit)
        let live = asks.filter { !$0.isOrphaned && now.timeIntervalSince($0.createdAt) <= askMaxAge }
        let stale = asks.filter { $0.isOrphaned || now.timeIntervalSince($0.createdAt) > askMaxAge }
        let rows = agentRows(db, now: now, policy: entropyPolicy)
        return Snapshot(
            available: true,
            agents: rows.agents,
            pendingAsks: Array(live.prefix(keep)),
            staleAsks: Array(stale),
            activity: activityRows(db, limit: activityLimit),
            agentEntropy: rows.entropy
        )
        #else
        return Snapshot()
        #endif
    }

    // MARK: - Agents

    /// Read agent rows. Returns [] if the DB is missing, locked, or schema-old.
    public static func readAgents(path: String, now: Date = Date()) -> [AgentActivitySnapshot] {
        #if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        return agentRows(db, now: now, policy: .current).agents
        #else
        return []
        #endif
    }

    /// The gate's own measured entropy, one element per agent that has actually
    /// been scored.
    ///
    /// This is the number the pill should show when no detector socket is
    /// attached — `agents.entropy_score` is written by
    /// `ShannonGate._handle_message` as `decision.computed_H`, stamped with the
    /// same `last_seen_ns` used as `measuredAt` here.
    ///
    /// Fail-closed behaviour, in order:
    /// - DB missing/locked/unopenable → `[]` (the caller reports `.absent`).
    /// - `entropy_score` column absent (pre-`entropy_score` DB) → `[]`.
    /// - `entropy_score` SQL NULL → row skipped.
    /// - `entropy_score` exactly `0.0` → row skipped. The column is
    ///   `REAL DEFAULT 0.0`, so an unscored row is indistinguishable from a
    ///   genuine zero; both are refused rather than rendered as total collapse.
    /// - `last_seen_ns` absent or ≤ 0 → row skipped: a value with no timestamp
    ///   cannot be aged, and an un-ageable value must never be called current.
    /// - non-finite, negative, over `policy.maxBits`, or future-dated beyond
    ///   `EntropyPolicy.clockSkewTolerance` → row skipped by
    ///   `EntropyMeasurement.init?`.
    ///
    /// Nothing here invents a value; if every row is refused the result is empty
    /// and the reading resolves to `.absent`.
    public static func readAgentEntropy(
        path: String,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> [EntropyMeasurement] {
        #if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        return agentRows(db, now: now, policy: policy).entropy
        #else
        return []
        #endif
    }

    #if canImport(SQLite3)
    /// Agent rows and their measured entropy, from one pass over `agents`.
    struct AgentRows {
        var agents: [AgentActivitySnapshot] = []
        var entropy: [EntropyMeasurement] = []
    }

    private static func agentRows(
        _ db: OpaquePointer, now: Date, policy: EntropyPolicy
    ) -> AgentRows {
        // Preferred (current hub schema).
        //
        // `connected` is derived from `disconnected_at`, which the old reader
        // ignored entirely — that is why agents that hung up two days ago still
        // rendered as current. The gate NULLs the column on reconnect, so a
        // non-NULL value newer than `last_seen_ns` means "definitely gone".
        //
        // `heartbeat` is when the gate last *proved* the connection was open.
        // Without it, "connected but quiet" and "gate was killed with the row
        // still open" look identical on disk, and the only way to tell them
        // apart was to age out `last_seen_ns` — which reported a perfectly
        // healthy agent as offline the moment it stopped talking for a few
        // minutes. The gate now stamps it every 15 s; see `heartbeat_agents`.
        //
        // `message_count` on the row is unreliable (the gate only bumps it on
        // some paths — grok_build showed 1 against 5 real rows), so the real
        // count from `agent_messages` wins when it is higher.
        //
        // `entropy_score` is gate-computed message H. Age it from
        // `entropy_updated_ns` (last *substantive* write), not `last_seen_ns`
        // (which heartbeats still refresh). Using last_seen made a frozen
        // ~2.38 bit attach-status score look "live" forever.
        let sqlBeat = """
            SELECT a.agent_id, a.status,
                   CAST(a.last_seen_ns / 1000000000.0 AS REAL) AS last_seen,
                   a.entropy_score,
                   COALESCE(a.task_summary, ''),
                   MAX(COALESCE(a.message_count, 0),
                       (SELECT COUNT(*) FROM agent_messages m WHERE m.agent_id = a.agent_id)),
                   CASE WHEN a.disconnected_at IS NULL
                          OR a.disconnected_at < a.last_seen_ns THEN 1 ELSE 0 END AS connected,
                   CAST(COALESCE(a.heartbeat_ns, 0) / 1000000000.0 AS REAL) AS heartbeat,
                   CAST(COALESCE(a.entropy_updated_ns, 0) / 1000000000.0 AS REAL) AS entropy_updated
            FROM agents a;
            """
        if let rows = query(db, sqlBeat, now: now, policy: policy) { return rows }

        // Same schema without `entropy_updated_ns` / with heartbeat.
        let sqlBeatNoEntTs = """
            SELECT a.agent_id, a.status,
                   CAST(a.last_seen_ns / 1000000000.0 AS REAL) AS last_seen,
                   a.entropy_score,
                   COALESCE(a.task_summary, ''),
                   MAX(COALESCE(a.message_count, 0),
                       (SELECT COUNT(*) FROM agent_messages m WHERE m.agent_id = a.agent_id)),
                   CASE WHEN a.disconnected_at IS NULL
                          OR a.disconnected_at < a.last_seen_ns THEN 1 ELSE 0 END AS connected,
                   CAST(COALESCE(a.heartbeat_ns, 0) / 1000000000.0 AS REAL) AS heartbeat
            FROM agents a;
            """
        if let rows = query(db, sqlBeatNoEntTs, now: now, policy: policy) { return rows }

        // Same schema without `heartbeat_ns` (gate not yet restarted on the
        // migration). Liveness then falls back to ageing `last_seen_ns`.
        let sqlNS = """
            SELECT a.agent_id, a.status,
                   CAST(a.last_seen_ns / 1000000000.0 AS REAL) AS last_seen,
                   a.entropy_score,
                   COALESCE(a.task_summary, ''),
                   MAX(COALESCE(a.message_count, 0),
                       (SELECT COUNT(*) FROM agent_messages m WHERE m.agent_id = a.agent_id)),
                   CASE WHEN a.disconnected_at IS NULL
                          OR a.disconnected_at < a.last_seen_ns THEN 1 ELSE 0 END AS connected
            FROM agents a;
            """
        if let rows = query(db, sqlNS, now: now, policy: policy) { return rows }

        // Legacy seconds-based schema without `disconnected_at`: we cannot prove
        // the connection state, so report `.observed` (unproven) rather than
        // claiming the agent is live.
        let sqlLegacy = """
            SELECT agent_id, status, last_seen,
                   entropy_score,
                   COALESCE(task_summary, ''),
                   0, -1
            FROM agents;
            """
        if let rows = query(db, sqlLegacy, now: now, policy: policy) { return rows }

        // Migration safety: a database predating `entropy_score` entirely. Every
        // SELECT above names the column, so without this the agent list itself
        // would come back empty on such a DB. Agents still read; entropy is
        // simply absent, which is the honest answer.
        let sqlNoEntropy = """
            SELECT agent_id, status, last_seen, NULL,
                   COALESCE(task_summary, ''),
                   0, -1
            FROM agents;
            """
        return query(db, sqlNoEntropy, now: now, policy: policy) ?? AgentRows()
    }

    private static func query(
        _ db: OpaquePointer, _ sql: String, now: Date, policy: EntropyPolicy
    ) -> AgentRows? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var out = AgentRows()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = string(stmt, 0)
            guard !id.isEmpty else { continue }
            let statusRaw = string(stmt, 1)
            let lastSeen = sqlite3_column_double(stmt, 2)
            // Column 3 is the gate's measured H. NULL (never written, or an
            // older schema) is not a number and must not become one.
            let entropyIsNull = sqlite3_column_type(stmt, 3) == SQLITE_NULL
            let entropyRaw = entropyIsNull ? 0 : sqlite3_column_double(stmt, 3)
            let task = string(stmt, 4)
            let msgCount = Int(sqlite3_column_int(stmt, 5))
            let connectedFlag = Int(sqlite3_column_int(stmt, 6))
            let presence: AgentPresence = connectedFlag == 1
                ? .live
                : (connectedFlag == 0 ? .offline : .observed)
            // Absent column (older schema) or 0 → no heartbeat evidence at all,
            // which the merge layer must handle differently from a *stale* one.
            let beat = sqlite3_column_count(stmt) > 7 ? sqlite3_column_double(stmt, 7) : 0
            // Column 8 = entropy_updated_ns (seconds). When the column exists,
            // NEVER fall back to last_seen — heartbeats refresh last_seen and
            // would keep a frozen attach-status H (~2.38) looking live forever.
            let hasEntropyUpdatedCol = sqlite3_column_count(stmt) > 8
            let entropyUpdated = hasEntropyUpdatedCol ? sqlite3_column_double(stmt, 8) : 0
            let entropyMeasuredAt = GateEntropyClock.measuredAtSeconds(
                hasEntropyUpdatedColumn: hasEntropyUpdatedCol,
                entropyUpdatedSeconds: entropyUpdated,
                lastSeenSeconds: lastSeen
            )

            let cleanTask = AgentActivitySnapshot.looksLikeSecretOrJunk(task)
                ? ""
                : AgentActivitySnapshot.shorten(task, max: 120)
            // A disconnected agent is not doing anything, whatever the last
            // status write said. Truth beats the stored string.
            let status = presence == .offline ? AgentRunStatus.idle : AgentRunStatus(raw: statusRaw)

            // Measured entropy, but only when the row can actually support the
            // claim. `entropy_score` is `REAL DEFAULT 0.0`, so an unscored row
            // is refused. When `entropy_updated_ns` exists and is 0, refuse
            // refuse (no honest clock) — do not age from last_seen.
            // Integrity: gate-written `decision.computed_H` only.
            if !entropyIsNull, entropyRaw > 0, let measuredAt = entropyMeasuredAt,
               let measurement = EntropyIntegrity.accept(
                   bits: entropyRaw,
                   deltaH: nil,
                   collapsed: nil,
                   source: .gate(agentId: id, presence: presence),
                   measuredAt: Date(timeIntervalSince1970: measuredAt),
                   now: now,
                   policy: policy
               ) {
                out.entropy.append(measurement)
            }

            out.agents.append(AgentActivitySnapshot(
                id: id,
                displayName: id.replacingOccurrences(of: "_", with: " ").capitalized,
                status: status,
                lastTask: cleanTask,
                source: "gate",
                updatedAt: lastSeen > 0 ? Date(timeIntervalSince1970: lastSeen) : .distantPast,
                resumable: status.isBusy,
                historyCount: msgCount,
                presence: presence,
                heartbeatAt: beat > 0 ? Date(timeIntervalSince1970: beat) : nil
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

        /// "12s" / "4m" / "2d" since the agent asked. Computed at read time, so
        /// it stays correct as long as something re-renders — see
        /// `AgentActivityReader.FullSnapshot.renderSignature(at:)`.
        public var waitingFor: String { waitingFor(at: Date()) }

        public func waitingFor(at now: Date) -> String {
            AgentActivitySnapshot.age(since: createdAt, now: now)
        }
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

    /// How many raw rows to consider per actionable slot the caller asked for.
    /// The SQL orders actionable rows first, so `limit` alone would already fill
    /// `pendingAsks`; the extra headroom is what makes `staleAsks` a useful
    /// count rather than "whatever was left over".
    private static let askFetchMultiplier = 4
    /// Hard ceiling on rows pulled per poll. A pathological `agent_interactions`
    /// table (thousands of never-resolved rows) must not be loaded into the UI
    /// process every 1.5 s.
    private static let askFetchCeiling = 64

    /// `created_at_ns` below this is older than `maxAge` — i.e. aged out.
    /// Clamped so an absurd `maxAge` cannot trap on `Int64` conversion.
    static func staleCutoffNs(now: Date, maxAge: TimeInterval) -> Int64 {
        let seconds = now.timeIntervalSince1970 - maxAge
        guard seconds.isFinite else { return maxAge > 0 ? .min : .max }
        guard seconds > -9.2e9 else { return .min }
        guard seconds < 9.2e9 else { return .max }
        return Int64(seconds * 1_000_000_000)
    }

    #if canImport(SQLite3)
    /// Open approvals, **actionable first**, then newest first within each group.
    ///
    /// - Parameters:
    ///   - limit: how many *actionable* asks the caller wants. The fetch is a
    ///     bounded multiple of it (see `askFetchMultiplier`/`askFetchCeiling`),
    ///     never the whole table.
    ///   - staleBeforeNs: `created_at_ns` strictly below this has aged out.
    ///     Mirrors the Swift-side age filter so the SQL sort agrees with the
    ///     classification the caller will apply.
    private static func pendingAsks(
        _ db: OpaquePointer,
        limit: Int,
        staleBeforeNs: Int64
    ) -> [PendingAsk] {
        guard limit > 0 else { return [] }
        let fetch = min(max(1, limit) * askFetchMultiplier, askFetchCeiling)
        // LEFT JOIN so an ask from an agent with no `agents` row is *not*
        // declared orphaned — we only drop what we can prove is dead.
        //
        // The ORDER BY repeats the orphan/age predicate instead of the row
        // limit being blind to it: with N stale rows and one live one, a plain
        // `ORDER BY created_at_ns DESC LIMIT 5` returned five corpses and the
        // answerable ask was never fetched at all.
        let sql = """
            SELECT i.interaction_id, i.agent_id, i.prompt,
                   CAST(i.created_at_ns / 1000000000.0 AS REAL),
                   CASE WHEN a.disconnected_at IS NOT NULL
                         AND a.disconnected_at > i.created_at_ns THEN 1 ELSE 0 END
            FROM agent_interactions i
            LEFT JOIN agents a ON a.agent_id = i.agent_id
            WHERE i.status = 'pending'
            ORDER BY CASE WHEN (a.disconnected_at IS NOT NULL
                                AND a.disconnected_at > i.created_at_ns)
                            OR i.created_at_ns < \(staleBeforeNs) THEN 1 ELSE 0 END ASC,
                     i.created_at_ns DESC
            LIMIT \(fetch);
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

        public var relativeAge: String { relativeAge(at: Date()) }

        public func relativeAge(at now: Date) -> String {
            AgentActivitySnapshot.age(since: at, now: now)
        }

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
