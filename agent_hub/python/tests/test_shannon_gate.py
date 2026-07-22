"""Tests for shannon_gate.py — auth hardening: HMAC signing, peer-UID allowlist,
bearer token. AuditDB and gate evaluation get a light smoke test too. No real
sockets, Keychain, or network access.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import shannon_gate as gate  # noqa: E402
from shannon_gate import (
    AgentMessage,
    AuditDB,
    ShannonGate,
    _peer_uid_allowed,
    verify_hmac_signature,
)


class TestHmacSignature:
    def test_valid_signature_accepted(self):
        secret = "test-secret"
        body = b'{"agent_id": "codex"}'
        import hashlib
        import hmac as hmac_mod

        sig = "sha256=" + hmac_mod.new(secret.encode(), body, hashlib.sha256).hexdigest()
        assert verify_hmac_signature(secret, body, sig) is True

    def test_invalid_signature_rejected(self):
        assert verify_hmac_signature("test-secret", b"body", "sha256=deadbeef") is False

    def test_missing_signature_rejected(self):
        assert verify_hmac_signature("test-secret", b"body", None) is False

    def test_tampered_body_rejected(self):
        secret = "test-secret"
        import hashlib
        import hmac as hmac_mod

        sig = "sha256=" + hmac_mod.new(secret.encode(), b"original", hashlib.sha256).hexdigest()
        assert verify_hmac_signature(secret, b"tampered", sig) is False


class TestPeerUidAllowlist:
    def test_no_socket_available_defaults_allow(self):
        writer = MagicMock()
        writer.get_extra_info.return_value = None
        assert _peer_uid_allowed(writer) is True

    @patch("shannon_gate.os.getuid", return_value=501)
    def test_matching_uid_allowed_linux_path(self, mock_getuid):
        import socket as socket_mod
        import struct

        if not hasattr(socket_mod, "SO_PEERCRED"):
            # Simulate Linux-style SO_PEERCRED presence for this test
            socket_mod.SO_PEERCRED = 17  # arbitrary constant for the test
            added = True
        else:
            added = False
        try:
            sock = MagicMock()
            creds = struct.pack("3i", 1234, 501, 501)
            sock.getsockopt.return_value = creds
            writer = MagicMock()
            writer.get_extra_info.return_value = sock
            assert _peer_uid_allowed(writer) is True
        finally:
            if added:
                del socket_mod.SO_PEERCRED

    @patch("shannon_gate.os.getuid", return_value=501)
    def test_mismatched_uid_rejected_linux_path(self, mock_getuid):
        import socket as socket_mod
        import struct

        if not hasattr(socket_mod, "SO_PEERCRED"):
            socket_mod.SO_PEERCRED = 17
            added = True
        else:
            added = False
        try:
            sock = MagicMock()
            creds = struct.pack("3i", 1234, 999, 999)  # different uid
            sock.getsockopt.return_value = creds
            writer = MagicMock()
            writer.get_extra_info.return_value = sock
            assert _peer_uid_allowed(writer) is False
        finally:
            if added:
                del socket_mod.SO_PEERCRED

    def test_exception_during_check_defaults_allow(self):
        writer = MagicMock()
        writer.get_extra_info.side_effect = Exception("boom")
        assert _peer_uid_allowed(writer) is True


class TestAuditDbAndGate:
    def test_audit_db_creates_and_gate_evaluates(self, tmp_path):
        db = AuditDB(tmp_path / "audit.db")
        g = ShannonGate(db)
        msg = AgentMessage(
            agent_id="codex",
            task_id="t1",
            message_type="status",
            payload={"text": "the quick brown fox jumps over the lazy dog"},
            timestamp_ns=1,
            shannon_H=0.0,
            confidence=0.9,
            message_id="m1",
        )
        decision = g.evaluate(msg)
        assert decision.decision in ("pass", "flagged", "blocked")
