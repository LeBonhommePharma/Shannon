import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Thin read-only access to `~/.shannon/agent_hub.db` written by `hub/shannon_gate.py`.
///
/// Claude's hub enhancements keep a live `agents` table (status, last_seen_ns,
/// entropy_score, task_summary). The notch pill merges this with pet folders so
/// the UI reflects actual gate connections when the daemon is running — and
/// still works offline from pets alone when it is not.
public enum GateDBReader {
    /// Read agent rows. Returns [] if the DB is missing, locked, or schema-old.
    public static func readAgents(path: String) -> [AgentActivitySnapshot] {
        #if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }

        // Prefer the Claude-enhanced schema (last_seen_ns nanoseconds).
        let sqlNS = """
            SELECT agent_id, status,
                   CAST(last_seen_ns / 1000000000.0 AS REAL) AS last_seen,
                   COALESCE(entropy_score, 0),
                   COALESCE(task_summary, ''),
                   COALESCE(message_count, 0)
            FROM agents;
            """
        if let rows = query(db, sqlNS) { return rows }

        // Legacy seconds-based last_seen (older hub builds).
        let sqlLegacy = """
            SELECT agent_id, status, last_seen,
                   COALESCE(entropy_score, 0),
                   COALESCE(task_summary, ''),
                   0
            FROM agents;
            """
        return query(db, sqlLegacy) ?? []
        #else
        return []
        #endif
    }

    #if canImport(SQLite3)
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
            // entropy available at col 3 — reserved for future pill strip binding
            _ = sqlite3_column_double(stmt, 3)
            let task = string(stmt, 4)
            let msgCount = Int(sqlite3_column_int(stmt, 5))
            let cleanTask = AgentActivitySnapshot.looksLikeSecretOrJunk(task)
                ? ""
                : AgentActivitySnapshot.shorten(task, max: 120)
            out.append(AgentActivitySnapshot(
                id: id,
                displayName: id.replacingOccurrences(of: "_", with: " ").capitalized,
                status: AgentRunStatus(raw: statusRaw),
                lastTask: cleanTask,
                source: "gate",
                updatedAt: lastSeen > 0 ? Date(timeIntervalSince1970: lastSeen) : .distantPast,
                resumable: AgentRunStatus(raw: statusRaw).isBusy,
                historyCount: msgCount
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
