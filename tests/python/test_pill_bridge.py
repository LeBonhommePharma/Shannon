"""Tests for the Pill live-activity socket bridge."""

from __future__ import annotations

import json
import os
import socket
import stat
import uuid

import pytest
from shannon.pill_bridge import (
    PillBridgeServer,
    default_socket_path,
    encode_frame,
    status_payload,
)


class FakeDetector:
    def __init__(self, **overrides):
        self._values = {
            "current_entropy": 8.42,
            "delta_h": -3.51,
            "is_collapsed": False,
            "token_count": 1024,
            "backend": "cpp",
        }
        self._values.update(overrides)

    def __getattr__(self, name):
        try:
            return self._values[name]
        except KeyError as exc:
            raise AttributeError(name) from exc


class ExplodingDetector:
    """A detector that has not seen tokens yet and raises on every property."""

    def __getattr__(self, name):
        raise RuntimeError("no tokens observed")


@pytest.fixture
def socket_path(tmp_path):
    # Keep the path short: sun_path is 104 bytes.
    path = f"/tmp/shannon-pill-test-{uuid.uuid4().hex[:8]}.sock"
    yield path
    if os.path.exists(path):
        os.unlink(path)


# -- payload projection ----------------------------------------------------


def test_status_payload_uses_snake_case_schema():
    payload = status_payload(FakeDetector(), agent="flexaid-runner")
    assert payload == {
        "entropy": 8.42,
        "delta_h": -3.51,
        "collapsed": False,
        "token_count": 1024,
        "backend": "cpp",
        "agent": "flexaid-runner",
    }


def test_agent_field_omitted_when_unset():
    assert "agent" not in status_payload(FakeDetector())


def test_payload_survives_detector_that_raises():
    # A fresh detector must still yield a well-formed frame, not a 500.
    payload = status_payload(ExplodingDetector())
    assert payload["entropy"] == 0.0
    assert payload["collapsed"] is False
    assert payload["token_count"] == 0
    assert payload["backend"] == "unknown"


def test_payload_coerces_types():
    payload = status_payload(FakeDetector(current_entropy=7, token_count=3.0, collapsed=1))
    assert isinstance(payload["entropy"], float)
    assert isinstance(payload["token_count"], int)
    assert isinstance(payload["collapsed"], bool)


def test_frames_are_newline_terminated():
    frame = encode_frame({"entropy": 1.0})
    assert frame.endswith(b"\n")
    assert b"\n" not in frame[:-1]
    assert json.loads(frame) == {"entropy": 1.0}


# -- socket round trip -----------------------------------------------------


def _request(path, payload):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(3.0)
    client.connect(path)
    try:
        client.sendall(payload)
        buf = b""
        while b"\n" not in buf:
            chunk = client.recv(1024)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.split(b"\n", 1)[0])
    finally:
        client.close()


def test_status_round_trip_over_socket(socket_path):
    server = PillBridgeServer(FakeDetector(), socket_path=socket_path, agent="pytest")
    with server:
        server.serve_in_thread()
        response = _request(socket_path, b'{"command": "status"}\n')

    assert response["entropy"] == 8.42
    assert response["token_count"] == 1024
    assert response["agent"] == "pytest"


def test_unknown_command_is_rejected(socket_path):
    server = PillBridgeServer(FakeDetector(), socket_path=socket_path)
    with server:
        server.serve_in_thread()
        response = _request(socket_path, b'{"command": "shutdown"}\n')

    assert "error" in response
    assert "shutdown" in response["error"]


def test_malformed_request_is_rejected(socket_path):
    server = PillBridgeServer(FakeDetector(), socket_path=socket_path)
    with server:
        server.serve_in_thread()
        response = _request(socket_path, b"not json\n")

    assert response["error"] == "malformed request"


def test_socket_is_owner_only(socket_path):
    # The entropy trace is agent-internal; no other local user should read it.
    server = PillBridgeServer(FakeDetector(), socket_path=socket_path)
    with server:
        mode = stat.S_IMODE(os.stat(socket_path).st_mode)
        assert mode == 0o600


def test_stale_socket_is_replaced(socket_path):
    with open(socket_path, "w") as handle:
        handle.write("")
    server = PillBridgeServer(FakeDetector(), socket_path=socket_path)
    with server:
        server.serve_in_thread()
        assert _request(socket_path, b'{"command": "status"}\n')["backend"] == "cpp"


def test_socket_removed_on_stop(socket_path):
    server = PillBridgeServer(FakeDetector(), socket_path=socket_path)
    server.start()
    assert os.path.exists(socket_path)
    server.stop()
    assert not os.path.exists(socket_path)


def test_overlong_socket_path_rejected():
    with pytest.raises(ValueError, match="exceeds"):
        PillBridgeServer(FakeDetector(), socket_path="/tmp/" + "x" * 200 + ".sock")


def test_serve_forever_requires_start():
    server = PillBridgeServer(FakeDetector(), socket_path="/tmp/unused-shannon.sock")
    with pytest.raises(RuntimeError, match="start()"):
        server.serve_forever()


# -- path resolution -------------------------------------------------------


def test_default_socket_path_honours_env(monkeypatch):
    monkeypatch.setenv("SHANNON_PILL_SOCKET", "/tmp/custom-shannon.sock")
    assert str(default_socket_path()) == "/tmp/custom-shannon.sock"


def test_default_socket_path_falls_back_to_home(monkeypatch):
    monkeypatch.delenv("SHANNON_PILL_SOCKET", raising=False)
    assert default_socket_path().name == "pill.sock"
    assert default_socket_path().parent.name == ".shannon"
