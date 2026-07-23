import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Write-side client for `hub/shannon_gate.py`'s Unix socket.
///
/// The pill is otherwise read-only — it renders pets and the gate's SQLite
/// tables. Resolving an approval is the one thing it must *write*, and it has to
/// go over the socket: the gate owns interaction state and only clears a row in
/// response to an `approval_response` message. Writing the DB directly would
/// leave the waiting agent blocked forever.
///
/// Protocol, mirroring `hub/AgentHubApp.swift` GateSocketClient:
///   1. connect to /tmp/shannon.sock
///   2. send a registration line — the gate rejects any peer whose `agent_id` is
///      not in VALID_AGENTS, and "local_test" is the entry reserved for local UI
///   3. send the approval envelope
///
/// One short-lived connection per approval. The pill approves rarely, and a
/// persistent socket would occupy the gate's single connection slot per agent id
/// — which the hub popup also wants.
public enum GateApprovalClient {

    public static let defaultSocketPath = "/tmp/shannon.sock"

    public enum ApprovalError: Error, Equatable {
        case socketUnavailable
        case connectFailed(Int32)
        case writeFailed(Int32)
    }

    /// Resolve one pending ask. `interactionId` MUST be the gate's own id from
    /// `agent_interactions` — a fresh UUID silently fails to match any row.
    @discardableResult
    public static func resolve(
        interactionId: String,
        agentId: String,
        approved: Bool,
        socketPath: String = defaultSocketPath
    ) throws -> Bool {
        #if canImport(Darwin)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ApprovalError.socketUnavailable
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ApprovalError.connectFailed(errno) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sun_path is a fixed C array; leave room for the NUL terminator.
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw ApprovalError.socketUnavailable }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ApprovalError.connectFailed(errno) }

        try writeLine(fd: fd, object: registrationPayload())
        try writeLine(fd: fd, object: approvalPayload(
            interactionId: interactionId, agentId: agentId, approved: approved
        ))
        return true
        #else
        throw ApprovalError.socketUnavailable
        #endif
    }

    // MARK: - Pure payload builders (unit-tested without a socket)

    /// Registration line. "local_test" is the VALID_AGENTS entry reserved for
    /// local UI clients; any other id is rejected by the gate at handshake.
    public static func registrationPayload() -> [String: Any] {
        ["agent_id": "local_test", "task_id": "pill_ui"]
    }

    /// The envelope `_dispatch` routes to its approval branch. That branch keys
    /// off message_type plus either an "approved" field or kind ==
    /// "approval_response"; this payload carries both so it cannot be mistaken
    /// for an ordinary broadcast.
    public static func approvalPayload(
        interactionId: String,
        agentId: String,
        approved: Bool
    ) -> [String: Any] {
        [
            "agent_id": "local_test",
            "task_id": "pill_ui",
            "message_type": "approval_response",
            "confidence": 1.0,
            "shannon_H": 0.0,
            "payload": [
                "target_agent": agentId,
                "approved": approved,
                "interaction_id": interactionId,
                "source": "pill_ui",
                "kind": "approval_response",
            ] as [String: Any],
        ]
    }

    #if canImport(Darwin)
    private static func writeLine(fd: Int32, object: [String: Any]) throws {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else {
            throw ApprovalError.writeFailed(EINVAL)
        }
        data.append(0x0A)  // the gate frames on newlines
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw ApprovalError.writeFailed(EINVAL) }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base + sent, data.count - sent, 0)
                if n <= 0 { throw ApprovalError.writeFailed(errno) }
                sent += n
            }
        }
    }
    #endif
}
