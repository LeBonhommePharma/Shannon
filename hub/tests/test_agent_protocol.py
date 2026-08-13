"""Tests for hub/agent_protocol.py.

Hermeticity contract for this file
----------------------------------
Nothing here may depend on ambient machine state — no live gate, no
production socket, no network, no wall clock. In particular the
"gate not running" case is asserted against a socket path this test owns
under $TMPDIR, never against `ap.SOCKET_PATH` (/tmp/shannon.sock), which may
well have a real daemon on it.
"""

import json
import os
import socket as _socket
import threading
import time
import uuid
from unittest.mock import MagicMock, patch

import agent_protocol as ap
import pytest


@pytest.fixture
def absent_socket_path(tmp_path) -> str:
    """A Unix socket path inside the test's own tmp dir, proven not to exist.

    `tmp_path` is unique per test, so nothing can be listening; the assertions
    below make that a checked precondition rather than an assumption. Using
    the real `ap.SOCKET_PATH` here would make the verdict depend on whether a
    gate happens to be running on this machine.
    """
    path = str(tmp_path / "definitely-absent.sock")
    assert not os.path.exists(path)
    # Belt and braces: prove nothing answers on it.
    probe = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
    try:
        with pytest.raises(OSError):
            probe.connect(path)
    finally:
        probe.close()
    return path


class TestAgentClientConstruction:
    def test_valid_agent_socket_mode(self):
        client = ap.AgentClient("science", "task_1")
        assert client.agent_id == "science"
        assert client.task_id == "task_1"
        assert client.mode == "socket"

    def test_valid_agent_http_mode(self):
        client = ap.AgentClient("codex", "task_1", mode="http")
        assert client.mode == "http"
        assert client.http_url == ap.DEFAULT_HTTP_URL

    def test_unknown_agent_raises(self):
        with pytest.raises(ValueError):
            ap.AgentClient("mallory", "task_1")

    def test_invalid_mode_raises(self):
        with pytest.raises(ValueError):
            ap.AgentClient("science", "task_1", mode="carrier_pigeon")

    def test_http_url_trailing_slash_stripped(self):
        client = ap.AgentClient("codex", "t1", mode="http", http_url="http://x.test:1234/")
        assert client.http_url == "http://x.test:1234"

    def test_local_client_helper_raises_when_gate_not_running(
        self, absent_socket_path, monkeypatch
    ):
        # local_client() eagerly connects; with no Shannon Gate socket present
        # this should surface a clear ConnectionError rather than hang.
        #
        # The assertion is only meaningful if nothing is listening. It used to
        # be evaluated against the production socket `ap.SOCKET_PATH`
        # (/tmp/shannon.sock), so the verdict depended on whether the developer
        # happened to have a gate running: green on CI, red on a working
        # machine, and — worse — it would have gone green against a *real*
        # gate's error too. Point it at a path under $TMPDIR that this test
        # owns and has just proven to be absent.
        monkeypatch.setattr(ap, "SOCKET_PATH", absent_socket_path)
        with pytest.raises(ConnectionError):
            ap.local_client("dispatch", "t1")

    def test_local_client_error_names_the_missing_socket(
        self, absent_socket_path, monkeypatch
    ):
        # Fail closed *and* legibly: the refusal must say which socket was
        # tried, otherwise a misconfigured path is indistinguishable from a
        # dead gate.
        monkeypatch.setattr(ap, "SOCKET_PATH", absent_socket_path)
        with pytest.raises(ConnectionError) as excinfo:
            ap.local_client("dispatch", "t1")
        assert absent_socket_path in str(excinfo.value)

    def test_local_client_refuses_before_opening_any_socket(
        self, absent_socket_path, monkeypatch
    ):
        # The missing-socket check must short-circuit: no file descriptor is
        # created, so nothing can hang on a half-open connect. Any attempt to
        # build a socket here is an error, which also means this test can never
        # reach the live gate on /tmp/shannon.sock.
        monkeypatch.setattr(ap, "SOCKET_PATH", absent_socket_path)
        monkeypatch.setattr(
            ap.socket, "socket",
            lambda *a, **k: pytest.fail("connect() built a socket before checking the path"),
        )
        with pytest.raises(ConnectionError):
            ap.local_client("dispatch", "t1")

    def test_cloud_client_helper(self):
        client = ap.cloud_client("grok_build", "t1", http_url="http://x.test")
        assert client.agent_id == "grok_build"
        assert client.mode == "http"


@pytest.mark.skipif(not hasattr(_socket, "AF_UNIX"), reason="AF_UNIX sockets are POSIX-only")
class TestSocketResponseRouting:
    """The recv loop is the socket's only reader and must route frames.

    Regression for a two-reader race: _send_socket used to recv() directly
    while _recv_loop also read the same fd, so the gate_response for a send
    could be consumed and discarded by the loop (send returned {}), or a
    broadcast could be handed back as if it were the gate decision. These
    tests script a fake gate that interleaves frames deterministically.
    """

    @pytest.fixture
    def gate_socket_path(self):
        # /tmp + short uuid, not tmp_path: macOS pytest tmp dirs exceed the
        # 104-byte sun_path limit for *bound* sockets.
        path = f"/tmp/shannon-ap-test-{uuid.uuid4().hex[:8]}.sock"
        yield path
        if os.path.exists(path):
            os.unlink(path)

    @staticmethod
    def _fake_gate(path, frames_before_response, wrong_id_first=False):
        """Bind a scripted gate: welcome, then per-envelope interleaved frames."""
        srv = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
        srv.bind(path)
        srv.listen(1)

        def run():
            conn, _ = srv.accept()
            reader = conn.makefile("rb")
            reg = json.loads(reader.readline())
            conn.sendall(
                json.dumps({"type": "welcome", "agent_id": reg["agent_id"]}).encode() + b"\n"
            )
            envelope = json.loads(reader.readline())
            for frame in frames_before_response:
                conn.sendall(json.dumps(frame).encode() + b"\n")
            if wrong_id_first:
                conn.sendall(
                    json.dumps(
                        {"type": "gate_response", "message_id": "stale_99", "decision": "blocked"}
                    ).encode()
                    + b"\n"
                )
            conn.sendall(
                json.dumps(
                    {
                        "type": "gate_response",
                        "message_id": envelope["message_id"],
                        "decision": "pass",
                    }
                ).encode()
                + b"\n"
            )
            # Keep the connection open until the client closes.
            reader.read(1)
            conn.close()

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return srv, thread

    def _connected_client(self, monkeypatch, path):
        monkeypatch.setattr(ap, "SOCKET_PATH", path)
        client = ap.AgentClient("science", "t_route")
        client.connect()
        return client

    def test_broadcast_before_response_is_not_returned_as_decision(
        self, gate_socket_path, monkeypatch
    ):
        broadcast = {
            "type": "agent_message",
            "from": "dataset_runner",
            "message_type": "status",
            "payload": {"message": "docking 1ACJ"},
        }
        srv, thread = self._fake_gate(gate_socket_path, [broadcast])
        try:
            client = self._connected_client(monkeypatch, gate_socket_path)
            seen: list[dict] = []
            client.subscribe(seen.append)

            decision = client.send_status("phase A started")
            assert decision.get("decision") == "pass", (
                "the broadcast that arrived first must not be returned as the gate decision"
            )

            deadline = time.monotonic() + 5.0
            while not seen and time.monotonic() < deadline:
                time.sleep(0.02)
            assert seen and seen[0]["type"] == "agent_message", (
                "the interleaved broadcast must still reach subscribe callbacks"
            )
            client.close()
            thread.join(timeout=5.0)
        finally:
            srv.close()

    def test_stale_gate_response_for_other_message_is_skipped(
        self, gate_socket_path, monkeypatch
    ):
        srv, thread = self._fake_gate(gate_socket_path, [], wrong_id_first=True)
        try:
            client = self._connected_client(monkeypatch, gate_socket_path)
            decision = client.send_status("phase B0")
            assert decision.get("decision") == "pass"
            assert decision.get("message_id") != "stale_99"
            client.close()
            thread.join(timeout=5.0)
        finally:
            srv.close()

    def test_ping_frames_are_dropped_not_returned(self, gate_socket_path, monkeypatch):
        srv, thread = self._fake_gate(gate_socket_path, [{"type": "ping"}])
        try:
            client = self._connected_client(monkeypatch, gate_socket_path)
            decision = client.send_status("phase B")
            assert decision.get("decision") == "pass"
            client.close()
            thread.join(timeout=5.0)
        finally:
            srv.close()


class TestTokenAndPayloadEntropy:
    def test_token_entropy_empty(self):
        assert ap._token_entropy("") == 0.0

    def test_token_entropy_positive_for_diverse_text(self):
        assert ap._token_entropy("alpha beta gamma delta") > 0.0

    def test_payload_entropy_uses_known_text_keys(self):
        H = ap._payload_entropy({"text": "alpha beta gamma delta"})
        assert H > 0.0

    def test_payload_entropy_falls_back_to_values(self):
        H = ap._payload_entropy({"cf_value": -3.2, "rmsd": 1.1})
        assert H >= 0.0


class TestCredentialManagerCredentialCheck:
    def test_local_agent_always_true(self):
        assert ap.CredentialManager.credential_check("science") is True

    def test_cloud_agent_missing_token_raises(self):
        with patch.object(ap.CredentialManager, "load", return_value=None):
            with pytest.raises(ap.AuthError):
                ap.CredentialManager.credential_check("grok_build")

    def test_cloud_agent_valid_token_pings_endpoint(self):
        fake_resp = MagicMock(status_code=200)
        with patch.object(ap.CredentialManager, "load", return_value="tok"), \
             patch.object(ap, "HAS_REQUESTS", True), \
             patch.object(ap, "_requests", MagicMock(get=MagicMock(return_value=fake_resp)), create=True):
            assert ap.CredentialManager.credential_check("grok_build") is True

    def test_cloud_agent_rejected_token_raises(self):
        fake_resp = MagicMock(status_code=401)
        with patch.object(ap.CredentialManager, "load", return_value="tok"), \
             patch.object(ap, "HAS_REQUESTS", True), \
             patch.object(ap, "_requests", MagicMock(get=MagicMock(return_value=fake_resp)), create=True):
            with pytest.raises(ap.AuthError):
                ap.CredentialManager.credential_check("grok_build")

    def test_credential_manager_store_calls_security_cli(self):
        with patch("agent_protocol.subprocess.run", return_value=MagicMock(returncode=0)) as run:
            assert ap.CredentialManager.store("grok_build", "tok") is True
            args = run.call_args[0][0]
            assert args[0] == "security"
            assert "add-generic-password" in args

    def test_credential_manager_load_from_keychain(self):
        result = MagicMock(returncode=0, stdout="secret\n")
        with patch("agent_protocol.subprocess.run", return_value=result):
            assert ap.CredentialManager.load("grok_build") == "secret"
