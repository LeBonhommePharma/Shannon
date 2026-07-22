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

__all__ = ["PillBridgeServer", "default_socket_path", "status_payload"]

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


def status_payload(detector: _DetectorLike, agent: str | None = None) -> dict[str, Any]:
    """Project a detector into the pill's status schema.

    Reads defensively: a detector that has not seen any tokens yet raises on
    some properties rather than returning a neutral value, and the pill should
    still get a well-formed frame.
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
    }
    if agent is not None:
        payload["agent"] = agent
    return payload


def encode_frame(payload: dict[str, Any]) -> bytes:
    """Serialize one newline-terminated JSON frame."""
    return json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n"


class PillBridgeServer:
    """Unix-domain-socket server exposing detector state to the pill app.

    Not a general RPC surface: it answers ``status`` and nothing else, so a
    compromised local process cannot use it to drive the agent.
    """

    def __init__(
        self,
        detector: _DetectorLike,
        socket_path: str | os.PathLike[str] | None = None,
        agent: str | None = None,
    ) -> None:
        self.detector = detector
        self.agent = agent
        self.socket_path = Path(socket_path) if socket_path else default_socket_path()
        if len(str(self.socket_path)) > _MAX_SOCKET_PATH:
            raise ValueError(f"socket path exceeds {_MAX_SOCKET_PATH} bytes: {self.socket_path}")
        self._sock: socket.socket | None = None
        self._stop = threading.Event()

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

    def stop(self) -> None:
        self._stop.set()
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
            with contextlib.closing(conn):
                with contextlib.suppress(OSError):
                    self.handle_connection(conn)

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
            return
        try:
            request = json.loads(raw)
            command = request.get("command", "")
        except (json.JSONDecodeError, AttributeError):
            conn.sendall(encode_frame({"error": "malformed request"}))
            return

        if command == "status":
            conn.sendall(encode_frame(status_payload(self.detector, self.agent)))
        else:
            conn.sendall(encode_frame({"error": f"unknown command: {command}"}))

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
