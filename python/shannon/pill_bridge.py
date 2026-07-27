"""Local socket bridge between the Shannon coordination layer and the Pill app.

The macOS pill (``Pill/``) is a pure consumer: it connects to a Unix domain
socket, writes one newline-terminated JSON request, and reads one
newline-terminated JSON response. Nothing leaves the machine — the socket is
created 0600 under the user's home directory and has no network listener.

Wire format (newline-delimited JSON, one exchange per connection)::

    -> {"command": "status"}
    <- {"entropy": 8.42, "delta_h": -3.51, "collapsed": false,
        "token_count": 1024, "backend": "cpp", "agent": "flexaid-runner"}

Usage::

    from shannon import ShannonCollapseDetector
    from shannon.pill_bridge import PillBridgeServer

    detector = ShannonCollapseDetector()
    with PillBridgeServer(detector, agent="flexaid-runner") as server:
        server.serve_forever()          # or run in a thread

Or standalone, emitting a synthetic trace for UI work::

    python -m shannon.pill_bridge --demo
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import socket
import threading
from pathlib import Path
from typing import Any, Protocol

__all__ = [
    "PillBridgeServer",
    "default_socket_path",
    "status_payload",
    "is_significant_event",
    "encode_frame",
]

# Keep well under sockaddr_un.sun_path (104 bytes on Darwin).
_MAX_SOCKET_PATH = 100


class _DetectorLike(Protocol):
    """The subset of ShannonCollapseDetector the bridge reads."""

    @property
    def current_entropy(self) -> float: ...
    @property
    def delta_h(self) -> float: ...
    @property
    def is_collapsed(self) -> bool: ...
    @property
    def token_count(self) -> int: ...
    @property
    def backend(self) -> str: ...


def default_socket_path() -> Path:
    """Socket location, overridable with ``SHANNON_PILL_SOCKET``.

    Matches ``ShannonBridge.defaultSocketPath`` on the Swift side.
    """
    override = os.environ.get("SHANNON_PILL_SOCKET")
    if override:
        return Path(override)
    return Path.home() / ".shannon" / "pill.sock"


def status_payload(
    detector: _DetectorLike,
    agent: str | None = None,
    *,
    kind: str = "status",
) -> dict[str, Any]:
    """Project a detector into the pill's status schema.

    Reads defensively: a detector that has not seen any tokens yet raises on
    some properties rather than returning a neutral value, and the pill should
    still get a well-formed frame.

    Optional fields ``z_score`` / ``token_snippet`` are included only when the
    detector exposes them — never invented.
    """

    def read(name: str, fallback: Any) -> Any:
        try:
            value = getattr(detector, name)
        except Exception:
            return fallback
        return fallback if value is None else value

    payload: dict[str, Any] = {
        "entropy": float(read("current_entropy", 0.0)),
        "delta_h": float(read("delta_h", 0.0)),
        "collapsed": bool(read("is_collapsed", False)),
        "token_count": int(read("token_count", 0)),
        "backend": str(read("backend", "unknown")),
        "kind": kind,
    }
    if agent is not None:
        payload["agent"] = agent
    z = read("z_score", None)
    if z is None:
        z = read("current_z_score", None)
    if z is not None:
        try:
            payload["z_score"] = float(z)
        except (TypeError, ValueError):
            pass
    snippet = read("token_snippet", None)
    if isinstance(snippet, str) and snippet.strip():
        payload["token_snippet"] = snippet.strip()[:240]
    return payload


def is_significant_event(
    previous: dict[str, Any] | None,
    current: dict[str, Any],
    *,
    abs_delta_h: float = 0.75,
) -> bool:
    """Whether a status frame is push-worthy (mirrors Swift ``BridgePushLogic``).

    Synthetic backends never push. Measured collapse and |ΔH| jumps do.
    """
    backend = str(current.get("backend", "")).strip().lower()
    if backend in {"demo", "idle", "unknown", "", "absent", "none", "placeholder", "simulated"}:
        return False
    if bool(current.get("collapsed")):
        return True
    try:
        d_h = abs(float(current.get("delta_h", 0.0)))
    except (TypeError, ValueError):
        d_h = 0.0
    if d_h >= abs_delta_h:
        return True
    if previous is not None:
        try:
            de = abs(float(current.get("entropy", 0.0)) - float(previous.get("entropy", 0.0)))
        except (TypeError, ValueError):
            de = 0.0
        if de >= abs_delta_h:
            return True
        if previous.get("collapsed") and not current.get("collapsed"):
            return True
    return False


def encode_frame(payload: dict[str, Any]) -> bytes:
    """Serialize one newline-terminated JSON frame."""
    return json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n"


class PillBridgeServer:
    """Unix-domain-socket server exposing detector state to the pill app.

    Commands:
    - ``status`` — one-shot NDJSON reply (poll heartbeat).
    - ``subscribe`` — keep the connection open and push significant events
      (measured collapse / large |ΔH|) as NDJSON frames. Engine never waits on
      slow consumers; push is best-effort and non-blocking for the detector.
    """

    def __init__(
        self,
        detector: _DetectorLike,
        socket_path: str | os.PathLike[str] | None = None,
        agent: str | None = None,
        *,
        push_poll_s: float = 0.05,
    ) -> None:
        self.detector = detector
        self.agent = agent
        self.push_poll_s = max(0.02, float(push_poll_s))
        self.socket_path = Path(socket_path) if socket_path else default_socket_path()
        if len(str(self.socket_path)) > _MAX_SOCKET_PATH:
            raise ValueError(f"socket path exceeds {_MAX_SOCKET_PATH} bytes: {self.socket_path}")
        self._sock: socket.socket | None = None
        self._stop = threading.Event()
        self._subs_lock = threading.Lock()
        self._subscribers: list[socket.socket] = []
        self._last_push: dict[str, Any] | None = None
        self._push_thread: threading.Thread | None = None

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> None:
        """Bind and listen. Removes a stale socket left by a previous run."""
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.suppress(FileNotFoundError):
            self.socket_path.unlink()

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(str(self.socket_path))
        # Owner-only: no other local user can read the agent's entropy trace.
        os.chmod(self.socket_path, 0o600)
        sock.listen(8)
        sock.settimeout(0.5)
        self._sock = sock
        self._stop.clear()
        self._push_thread = threading.Thread(
            target=self._push_loop, name="shannon-pill-push", daemon=True
        )
        self._push_thread.start()

    def stop(self) -> None:
        self._stop.set()
        with self._subs_lock:
            for s in self._subscribers:
                with contextlib.suppress(OSError):
                    s.close()
            self._subscribers.clear()
        if self._sock is not None:
            self._sock.close()
            self._sock = None
        with contextlib.suppress(FileNotFoundError):
            self.socket_path.unlink()

    def __enter__(self) -> PillBridgeServer:
        self.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.stop()

    # -- serving -----------------------------------------------------------

    def serve_forever(self) -> None:
        if self._sock is None:
            raise RuntimeError("start() must be called before serve_forever()")
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except TimeoutError:
                continue
            except OSError:
                break
            # Each connection is handled on a short-lived thread so subscribe
            # sockets do not block poll heartbeats.
            t = threading.Thread(
                target=self._serve_one, args=(conn,), name="shannon-pill-conn", daemon=True
            )
            t.start()

    def _serve_one(self, conn: socket.socket) -> None:
        try:
            self.handle_connection(conn)
        except OSError:
            with contextlib.suppress(OSError):
                conn.close()

    def serve_in_thread(self) -> threading.Thread:
        """Run `serve_forever` on a daemon thread and return it."""
        thread = threading.Thread(target=self.serve_forever, name="shannon-pill-bridge")
        thread.daemon = True
        thread.start()
        return thread

    def handle_connection(self, conn: socket.socket) -> None:
        conn.settimeout(2.0)
        raw = self._read_line(conn)
        if raw is None:
            conn.close()
            return
        try:
            request = json.loads(raw)
            command = request.get("command", "")
        except (json.JSONDecodeError, AttributeError):
            with contextlib.suppress(OSError):
                conn.sendall(encode_frame({"error": "malformed request"}))
            conn.close()
            return

        if command == "status":
            with contextlib.suppress(OSError):
                conn.sendall(encode_frame(status_payload(self.detector, self.agent, kind="status")))
            conn.close()
            return
        if command == "subscribe":
            # Long-lived push socket — owned by _push_loop until disconnect.
            conn.settimeout(None)
            with self._subs_lock:
                self._subscribers.append(conn)
            return
        with contextlib.suppress(OSError):
            conn.sendall(encode_frame({"error": f"unknown command: {command}"}))
        conn.close()

    def _push_loop(self) -> None:
        """Sample detector; fan-out significant events to subscribers."""
        while not self._stop.is_set():
            try:
                payload = status_payload(self.detector, self.agent, kind="event")
            except Exception:
                payload = None
            if payload is not None and is_significant_event(self._last_push, payload):
                self._broadcast(payload)
                self._last_push = payload
            elif payload is not None:
                # Track baseline without push (quiet frames stay polled).
                self._last_push = payload
            self._stop.wait(self.push_poll_s)

    def _broadcast(self, payload: dict[str, Any]) -> None:
        frame = encode_frame(payload)
        dead: list[socket.socket] = []
        with self._subs_lock:
            subs = list(self._subscribers)
        for s in subs:
            try:
                s.sendall(frame)
            except OSError:
                dead.append(s)
        if dead:
            with self._subs_lock:
                self._subscribers = [s for s in self._subscribers if s not in dead]
            for s in dead:
                with contextlib.suppress(OSError):
                    s.close()

    @staticmethod
    def _read_line(conn: socket.socket, limit: int = 8192) -> bytes | None:
        buf = bytearray()
        while b"\n" not in buf:
            chunk = conn.recv(1024)
            if not chunk:
                return None
            buf.extend(chunk)
            if len(buf) > limit:
                return None
        return bytes(buf.split(b"\n", 1)[0])


class _DemoDetector:
    """Synthetic detector so the pill UI can be driven without a live agent."""

    def __init__(self) -> None:
        self._n = 0

    def _tick(self) -> float:
        import math

        self._n += 1
        return 8.0 + 2.0 * math.sin(self._n / 12.0)

    @property
    def current_entropy(self) -> float:
        return self._tick()

    @property
    def delta_h(self) -> float:
        return -abs(self.current_entropy - 8.0)

    @property
    def is_collapsed(self) -> bool:
        return self.delta_h < -1.8

    @property
    def token_count(self) -> int:
        return self._n

    @property
    def backend(self) -> str:
        return "demo"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Shannon pill bridge server")
    parser.add_argument("--socket", default=None, help="socket path")
    parser.add_argument("--agent", default=None, help="agent label shown in the pill")
    parser.add_argument("--demo", action="store_true", help="serve a synthetic entropy trace")
    args = parser.parse_args(argv)

    if not args.demo:
        parser.error("only --demo is supported standalone; embed PillBridgeServer instead")

    server = PillBridgeServer(_DemoDetector(), socket_path=args.socket, agent=args.agent or "demo")
    with server:
        print(f"shannon pill bridge listening on {server.socket_path}")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
