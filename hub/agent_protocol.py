#!/usr/bin/env python3
"""
agent_protocol.py — FlexAIDdS Agent Hub Client Library
=======================================================
A zero-dependency (standard library only for socket mode) Python client
that lets any AI agent integration push messages to the Shannon Gate hub
and receive broadcasts from other agents.

Two transport modes
-------------------
socket  — Unix domain socket (/tmp/flexaidds_agent_hub.sock)
          Designed for local agents: DatasetRunner bridge, local test harnesses.
          Supports real-time .subscribe() callbacks via background thread.

http    — HTTP REST over TCP (default: http://127.0.0.1:8765)
          Designed for cloud agent integrations that can't reach a local socket:
          Codex (GitHub Actions), Claude Cowork/Dispatch/Science (cloud API),
          Grok Build (xAI API). Stateless request-response.

Quick start
-----------
  # Local agent (socket)
  from agent_protocol import AgentClient

  with AgentClient("science", "benchmark_v133") as c:
      c.send_status("Starting tENCoM vibrational entropy analysis")
      decision = c.send_result({"cf_value": -3.21, "rmsd": 1.4}, confidence=0.93)
      print(decision)   # {"decision": "pass", "gate_H": 2.1, ...}

  # Cloud agent (HTTP — e.g. Codex integration script)
  client = AgentClient("codex", "benchmark_v133", mode="http")
  client.send_result({"output": "Suggested fix: ...", "cf_value": -3.18}, confidence=0.85)

  # Subscribe to messages from other agents
  def on_message(msg):
      print(f"[{msg['from']}] {msg['message_type']}: {msg.get('payload')}")

  client = AgentClient("dispatch", "benchmark_v133")
  client.connect()
  client.subscribe(on_message)
  # ... do other work; on_message fires in background thread

Dependencies
------------
  socket mode: Python 3.11+ standard library only
  http mode:   requests (pip install requests)
  async API:   asyncio (stdlib)
"""

from __future__ import annotations

import asyncio
import json
import math
import os
import socket
import subprocess
import sys
import threading
import time
import warnings
from collections import Counter
from typing import Any, Callable, Optional

# HTTP transport (optional)
try:
    import requests as _requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False

# ── Constants ─────────────────────────────────────────────────────────────────
SOCKET_PATH: str = "/tmp/shannon.sock"
DEFAULT_HTTP_URL: str = "http://127.0.0.1:8765"
VALID_AGENTS: frozenset[str] = frozenset({
    "codex", "cowork", "dispatch", "science", "grok_build",
    "claude_code",      # local coding agent — C++ compilation, git, shell tasks
    "dataset_runner", "local_test",
})
RECV_BUFFER: int = 65536

# ── Agent identity metadata (2026-07-22 corrected icon map) ──────────────────
AGENT_ICONS: dict[str, str] = {
    "codex":          "🔵",   # OpenAI / GitHub Copilot
    "cowork":         "🟢",   # Claude Cowork            (was 🟣)
    "dispatch":       "🟤",   # Claude Dispatch
    "science":        "🔶",   # Claude Science (Fable 5)
    "grok_build":     "🟣",   # Grok Build / xAI         (was ⚫️)
    "claude_code":    "🟠",   # Claude Code — local C++/git  (was 🟢)
    "dataset_runner": "⚙️",   # DatasetRunner file watcher
    "local_test":     "⚪️",   # Integration testing
}

AGENT_AUTH_TYPE: dict[str, str] = {
    "codex":          "cloud",   # requires API key / OAuth
    "grok_build":     "cloud",   # requires API key / OAuth
    "cowork":         "local",   # authenticated via Unix socket shared secret
    "dispatch":       "local",
    "science":        "local",
    "claude_code":    "local",
    "dataset_runner": "local",
    "local_test":     "local",
}


# ── Auth error ────────────────────────────────────────────────────────────────

class AuthError(Exception):
    """
    Raised by CredentialManager.credential_check() when a cloud agent's
    token is missing, invalid, or has been revoked.

    Attributes
    ----------
    agent_id : str   — which agent failed
    reason   : str   — human-readable reason (no secrets)
    """

    def __init__(self, agent_id: str, reason: str) -> None:
        super().__init__(f"[{agent_id}] Auth error: {reason}")
        self.agent_id = agent_id
        self.reason   = reason


# ── Credential manager ────────────────────────────────────────────────────────

class CredentialManager:
    """
    Manages cloud-agent credentials via the macOS Keychain (security CLI proxy).
    Secrets are NEVER stored in plaintext files, SQLite, or environment vars
    beyond the optional fallback env-var lookup below.

    Keychain layout
    ---------------
    service  : "FlexAIDdS.AgentHub"
    account  : "<agent_id>.token"
    value    : the API key / OAuth access token
    """

    SERVICE = "FlexAIDdS.AgentHub"

    _AUTH_ENDPOINTS: dict[str, str] = {
        "codex":      "https://api.github.com/user",
        "grok_build": "https://api.x.ai/v1/models",
    }

    _FALLBACK_ENV: dict[str, tuple[str, ...]] = {
        "codex":      ("GITHUB_TOKEN", "OPENAI_API_KEY"),
        "grok_build": ("GROK_API_KEY", "XAI_API_KEY"),
    }

    @classmethod
    def load(cls, agent_id: str) -> Optional[str]:
        """Load token: Keychain first, then env-var fallback."""
        # 1. macOS Keychain via `security` CLI
        try:
            result = subprocess.run(
                [
                    "security", "find-generic-password",
                    "-s", cls.SERVICE,
                    "-a", f"{agent_id}.token",
                    "-w",
                ],
                capture_output=True, text=True, timeout=3,
            )
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
        except Exception:
            pass

        # 2. Env-var fallback (CI / development)
        for var in cls._FALLBACK_ENV.get(agent_id, ()):
            val = os.environ.get(var)
            if val:
                return val
        return None

    @classmethod
    def store(cls, agent_id: str, token: str) -> bool:
        """Store token in Keychain. Returns True on success."""
        try:
            subprocess.run(
                [
                    "security", "add-generic-password",
                    "-s", cls.SERVICE,
                    "-a", f"{agent_id}.token",
                    "-w", token,
                    "-U",   # update if already exists
                ],
                capture_output=True, timeout=5,
            )
            return True
        except Exception:
            return False

    @classmethod
    def credential_check(cls, agent_id: str, timeout: float = 5.0) -> bool:
        """
        Verify cloud agent credentials by pinging the auth endpoint.

        Local agents (socket) always return True — they authenticate via the
        in-memory HUB_SECRET, not stored credentials.

        Raises AuthError if the token is missing or rejected.
        """
        if AGENT_AUTH_TYPE.get(agent_id) != "cloud":
            return True

        token = cls.load(agent_id)
        if not token:
            raise AuthError(
                agent_id,
                "no credential found — run: security add-generic-password "
                f"-s {cls.SERVICE} -a {agent_id}.token -w <YOUR_TOKEN>",
            )

        endpoint = cls._AUTH_ENDPOINTS.get(agent_id)
        if not endpoint:
            return True

        if not HAS_REQUESTS:
            warnings.warn(
                f"requests not installed — skipping live auth ping for {agent_id}",
                stacklevel=2,
            )
            return True

        try:
            resp = _requests.get(
                endpoint,
                headers={"Authorization": f"Bearer {token}"},
                timeout=timeout,
            )
            if resp.status_code == 401:
                raise AuthError(agent_id, "token rejected (HTTP 401) — re-authenticate")
            if resp.status_code == 403:
                raise AuthError(agent_id, "token lacks required scope (HTTP 403)")
            return resp.status_code < 400
        except AuthError:
            raise
        except Exception as exc:
            # Network unreachable → soft pass (don't block local work)
            warnings.warn(
                f"Auth ping for {agent_id} skipped (network): {exc}",
                stacklevel=2,
            )
            return True


# ── Client-side entropy (mirrors gate, for self-reporting) ────────────────────

def _token_entropy(text: str) -> float:
    """
    Compute whitespace-token Shannon entropy of *text* (in bits).
    Used for auto-populating the shannon_H field when the agent doesn't
    supply its own estimate.
    """
    if not text or not text.strip():
        return 0.0
    tokens = text.lower().split()
    n = len(tokens)
    if n < 2:
        return 0.0
    counts = Counter(tokens)
    return round(-sum((c / n) * math.log2(c / n) for c in counts.values()), 4)


def _payload_entropy(payload: dict[str, Any]) -> float:
    """Aggregate token entropy across all string/numeric values in payload."""
    parts: list[str] = []
    for key in ("text", "content", "output", "message", "code",
                "analysis", "rationale", "suggested_code"):
        val = payload.get(key)
        if isinstance(val, str):
            parts.append(val)
    # Fall back to serialised JSON values if no known text keys
    if not parts:
        parts = [str(v) for v in payload.values()
                 if isinstance(v, (str, int, float))]
    return _token_entropy(" ".join(parts))


# ── AgentClient ───────────────────────────────────────────────────────────────

class AgentClient:
    """
    Multi-mode client for the FlexAIDdS Shannon Gate Agent Hub.

    Parameters
    ----------
    agent_id : str
        One of: "codex", "cowork", "dispatch", "science", "grok_build",
                "dataset_runner", "local_test"
    task_id : str
        Current task / benchmark label, e.g. "benchmark_v133_astex85"
    mode : {"socket", "http"}
        Transport mode. "socket" for local; "http" for cloud integrations.
    http_url : str
        Base URL for HTTP mode (default "http://127.0.0.1:8765").
        Override when using Tailscale / ngrok for remote access.
    auto_entropy : bool
        If True (default), estimate and attach shannon_H automatically to
        every outgoing message. The gate also computes its own H independently;
        this lets the gate detect H_mismatch (agent under-reports entropy).
    timeout : float
        Socket connection timeout in seconds (default 5.0).
    """

    def __init__(
        self,
        agent_id: str,
        task_id: str,
        mode: str = "socket",
        http_url: str = DEFAULT_HTTP_URL,
        auto_entropy: bool = True,
        timeout: float = 5.0,
    ) -> None:
        if agent_id not in VALID_AGENTS:
            raise ValueError(
                f"Unknown agent_id {agent_id!r}. "
                f"Valid: {sorted(VALID_AGENTS)}"
            )
        if mode not in ("socket", "http"):
            raise ValueError(f"mode must be 'socket' or 'http', got {mode!r}")

        self.agent_id = agent_id
        self.task_id = task_id
        self.mode = mode
        self.http_url = http_url.rstrip("/")
        self.auto_entropy = auto_entropy
        self.timeout = timeout

        # Internal state
        self._sock: Optional[socket.socket] = None
        self._connected: bool = False
        self._counter: int = 0
        self._callbacks: list[Callable[[dict], None]] = []
        self._recv_thread: Optional[threading.Thread] = None
        self._recv_buf: bytes = b""

        # Async transport state (populated by async_connect)
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None

    # ─────────────────────────────────────────────────────────────────────────
    # Connection management (socket mode)
    # ─────────────────────────────────────────────────────────────────────────

    def connect(self) -> "AgentClient":
        """
        Open a connection to the Shannon Gate Unix socket and register.
        No-op in HTTP mode (HTTP is connectionless).

        Returns self for chaining.

        Raises
        ------
        ConnectionError  if the socket file doesn't exist or is refused.
        RuntimeError     if registration fails (unknown agent_id on gate side).
        """
        if self.mode == "http":
            return self  # nothing to do

        if self._connected:
            return self

        if not os.path.exists(SOCKET_PATH):
            raise ConnectionError(
                f"Shannon Gate socket not found at {SOCKET_PATH}. "
                "Is shannon_gate.py running?"
            )

        try:
            self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._sock.settimeout(self.timeout)
            self._sock.connect(SOCKET_PATH)
            self._sock.settimeout(None)  # blocking reads after connect
        except (FileNotFoundError, ConnectionRefusedError, OSError) as exc:
            raise ConnectionError(
                f"Cannot connect to Shannon Gate: {exc}"
            ) from exc

        # Register this agent
        reg = json.dumps({
            "agent_id": self.agent_id,
            "task_id": self.task_id,
        }) + "\n"
        self._sock.sendall(reg.encode())

        # Receive welcome (blocking, short timeout)
        self._sock.settimeout(10.0)
        raw = self._sock.recv(RECV_BUFFER)
        self._sock.settimeout(None)

        welcome = json.loads(raw.decode().strip())
        if welcome.get("type") != "welcome":
            raise RuntimeError(
                f"Expected 'welcome' from gate, got: {welcome}"
            )

        self._connected = True

        # Start background receive thread
        self._recv_thread = threading.Thread(
            target=self._recv_loop, daemon=True, name=f"recv_{self.agent_id}"
        )
        self._recv_thread.start()

        return self

    def close(self) -> None:
        """Close the connection gracefully."""
        self._connected = False
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    # ─────────────────────────────────────────────────────────────────────────
    # High-level send API
    # ─────────────────────────────────────────────────────────────────────────

    def send_result(
        self,
        payload: dict[str, Any],
        confidence: float = 1.0,
        shannon_H: Optional[float] = None,
    ) -> dict[str, Any]:
        """
        Send a result message — the primary output type.

        Include in payload:
          "cf_value"   : float   — Contact Function score (docking)
          "rmsd"       : float   — Best-pose RMSD in Å
          "target_id"  : str     — e.g. "1ACJ"
          "pose_file"  : str     — path to best .pdb pose
          "text"       : str     — free-text analysis
          "output"     : str     — raw agent output

        Returns gate decision dict:
          {"decision": "pass"|"flagged"|"blocked",
           "gate_H": float, "gate_D": float, "reasons": [...]}
        """
        H = shannon_H if shannon_H is not None else (
            _payload_entropy(payload) if self.auto_entropy else 0.0
        )
        return self._send("result", payload, confidence, H)

    def send_status(
        self,
        message: str,
        details: Optional[dict[str, Any]] = None,
        confidence: float = 1.0,
    ) -> dict[str, Any]:
        """
        Send a status / progress update.

        Parameters
        ----------
        message  : Human-readable status string.
        details  : Optional structured data (e.g. {"step": 47, "total": 85}).
        """
        payload: dict[str, Any] = {"message": message}
        if details:
            payload.update(details)
        H = _token_entropy(message) if self.auto_entropy else 0.0
        return self._send("status", payload, confidence, H)

    def send_benchmark_update(
        self,
        completed: int,
        total: int = 85,
        best_cf: Optional[float] = None,
        best_rmsd: Optional[float] = None,
        active_target: Optional[str] = None,
    ) -> dict[str, Any]:
        """
        Push shared benchmark state to the hub (typically from DatasetRunner).
        Broadcasts to all connected agents so they share the same context.
        """
        payload: dict[str, Any] = {
            "completed": completed,
            "total": total,
            "best_cf": best_cf,
            "best_rmsd": best_rmsd,
            "active_target": active_target,
            "task_id": self.task_id,
        }
        return self._send("benchmark_update", payload, 1.0, 0.0)

    def send_code_suggestion(
        self,
        filename: str,
        line_start: int,
        line_end: int,
        original_code: str,
        suggested_code: str,
        rationale: str,
        confidence: float = 0.80,
    ) -> dict[str, Any]:
        """
        Propose a code change to LP for review.

        All code suggestions require LP's explicit approval regardless of gate
        decision. The gate will block suggestions with H ≥ 5.0 bits, and flag
        (but not block) those with H ∈ [3.5, 5.0).

        Parameters
        ----------
        filename       : e.g. "DatasetRunner.cpp"
        line_start     : first line affected (1-indexed)
        line_end       : last line affected
        original_code  : verbatim original snippet
        suggested_code : proposed replacement
        rationale      : why this change improves correctness / performance
        """
        payload: dict[str, Any] = {
            "filename": filename,
            "line_start": line_start,
            "line_end": line_end,
            "original_code": original_code,
            "suggested_code": suggested_code,
            "rationale": rationale,
            "requires_lp_approval": True,
        }
        combined = f"{suggested_code}\n{rationale}"
        H = _token_entropy(combined) if self.auto_entropy else 0.0
        return self._send("code_suggestion", payload, confidence, H)

    def send_alert(
        self,
        severity: str,
        message: str,
        details: Optional[dict[str, Any]] = None,
    ) -> dict[str, Any]:
        """
        Emit an alert (severity: "info" | "warning" | "critical").
        Alerts are broadcast to all connected agents and appear in the HUD.
        """
        payload: dict[str, Any] = {
            "severity": severity,
            "message": message,
        }
        if details:
            payload["details"] = details
        H = _token_entropy(message) if self.auto_entropy else 0.0
        return self._send("alert", payload, 1.0, H)

    # ─────────────────────────────────────────────────────────────────────────
    # Query API (read-only, bypass gate)
    # ─────────────────────────────────────────────────────────────────────────

    def query_benchmark_state(self) -> dict[str, Any]:
        """
        Returns the current shared FlexAIDdS benchmark run status:
          {"completed": int, "total": int, "best_cf": float,
           "best_rmsd": float, "active_target": str, ...}
        """
        return self._query("benchmark_state")

    def query_agent_list(self) -> dict[str, Any]:
        """Returns {"connected": [...agent_ids...], "count": int}."""
        return self._query("agent_list")

    def query_cf_reports(self, task_id: Optional[str] = None) -> dict[str, Any]:
        """
        Returns {agent_id: latest_cf_value} for the given task.
        Useful for computing inter-agent disagreement entropy locally.
        """
        return self._query("cf_reports", {"task_id": task_id or self.task_id})

    def query_recent_messages(self, limit: int = 50) -> list[dict[str, Any]]:
        """Returns the last *limit* messages from the audit log."""
        result = self._query("recent_messages", {"limit": limit})
        if isinstance(result, dict) and "data" in result:
            return result["data"]
        return result if isinstance(result, list) else []

    # ─────────────────────────────────────────────────────────────────────────
    # Subscribe (socket mode only)
    # ─────────────────────────────────────────────────────────────────────────

    def subscribe(self, callback: Callable[[dict[str, Any]], None]) -> None:
        """
        Register a callback that fires on every inbound message from other agents.
        The callback receives the full message dict including gate metadata.
        Executes in a background daemon thread — keep callbacks short.

        Only available in socket mode. Raises UserWarning in HTTP mode.
        """
        if self.mode != "socket":
            warnings.warn(
                "subscribe() is only supported in socket mode. "
                "HTTP mode is stateless — poll query_recent_messages() instead.",
                stacklevel=2,
            )
            return
        self._callbacks.append(callback)

    # ─────────────────────────────────────────────────────────────────────────
    # Async API
    # ─────────────────────────────────────────────────────────────────────────

    async def async_connect(self) -> dict[str, Any]:
        """
        Async variant of connect(). Returns the welcome message.

        Usage:
            welcome = await client.async_connect()
            decision = await client.async_send_result({"cf_value": -3.2}, 0.9)
            await client.async_close()
        """
        if self.mode != "socket":
            return {}
        self._reader, self._writer = await asyncio.open_unix_connection(
            SOCKET_PATH
        )
        reg = json.dumps({
            "agent_id": self.agent_id,
            "task_id": self.task_id,
        }) + "\n"
        self._writer.write(reg.encode())
        await self._writer.drain()

        raw = await asyncio.wait_for(self._reader.readline(), timeout=10.0)
        return json.loads(raw.decode().strip())

    async def async_send_result(
        self,
        payload: dict[str, Any],
        confidence: float = 1.0,
        shannon_H: Optional[float] = None,
    ) -> dict[str, Any]:
        """Async variant of send_result()."""
        H = shannon_H if shannon_H is not None else (
            _payload_entropy(payload) if self.auto_entropy else 0.0
        )
        return await self._async_send("result", payload, confidence, H)

    async def async_send_status(
        self,
        message: str,
        details: Optional[dict[str, Any]] = None,
        confidence: float = 1.0,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"message": message}
        if details:
            payload.update(details)
        H = _token_entropy(message) if self.auto_entropy else 0.0
        return await self._async_send("status", payload, confidence, H)

    async def async_query_benchmark_state(self) -> dict[str, Any]:
        return await self._async_send(
            "query", {"query_type": "benchmark_state"}, 1.0, 0.0
        )

    async def async_close(self) -> None:
        if self._writer:
            self._writer.close()
            try:
                await self._writer.wait_closed()
            except Exception:
                pass

    # ─────────────────────────────────────────────────────────────────────────
    # Context manager
    # ─────────────────────────────────────────────────────────────────────────

    def __enter__(self) -> "AgentClient":
        self.connect()
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    async def __aenter__(self) -> "AgentClient":
        await self.async_connect()
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.async_close()

    # ─────────────────────────────────────────────────────────────────────────
    # Internal helpers
    # ─────────────────────────────────────────────────────────────────────────

    def _next_id(self) -> str:
        self._counter += 1
        return f"{self.agent_id}_{self._counter}"

    def _build_envelope(
        self,
        message_type: str,
        payload: dict[str, Any],
        confidence: float,
        shannon_H: float,
    ) -> dict[str, Any]:
        return {
            "agent_id": self.agent_id,
            "task_id": self.task_id,
            "message_type": message_type,
            "payload": payload,
            "timestamp_ns": time.time_ns(),
            "shannon_H": round(shannon_H, 4),
            "confidence": max(0.0, min(1.0, confidence)),
            "message_id": self._next_id(),
        }

    def _send(
        self,
        message_type: str,
        payload: dict[str, Any],
        confidence: float,
        shannon_H: float,
    ) -> dict[str, Any]:
        envelope = self._build_envelope(
            message_type, payload, confidence, shannon_H
        )
        if self.mode == "socket":
            return self._send_socket(envelope)
        return self._send_http(envelope)

    def _query(
        self,
        query_type: str,
        extra: Optional[dict[str, Any]] = None,
    ) -> dict[str, Any]:
        qpayload: dict[str, Any] = {"query_type": query_type}
        if extra:
            qpayload.update(extra)
        return self._send("query", qpayload, 1.0, 0.0)

    # ── Socket transport ──────────────────────────────────────────────────────

    def _send_socket(self, envelope: dict[str, Any]) -> dict[str, Any]:
        if not self._connected or self._sock is None:
            raise RuntimeError(
                "Not connected. Call connect() or use the context manager."
            )
        data = (json.dumps(envelope) + "\n").encode()
        try:
            self._sock.sendall(data)
            # Synchronous read of gate response
            resp_raw = self._sock.recv(RECV_BUFFER)
            if resp_raw:
                # May contain multiple lines; parse the first complete JSON
                for line in resp_raw.decode().splitlines():
                    line = line.strip()
                    if line:
                        try:
                            return json.loads(line)
                        except json.JSONDecodeError:
                            continue
            return {}
        except OSError as exc:
            self._connected = False
            raise RuntimeError(f"Socket send failed: {exc}") from exc

    # ── HTTP transport ────────────────────────────────────────────────────────

    def _send_http(self, envelope: dict[str, Any]) -> dict[str, Any]:
        if not HAS_REQUESTS:
            raise ImportError(
                "HTTP mode requires 'requests': pip install requests"
            )
        endpoint = (
            f"{self.http_url}/state"
            if envelope["message_type"] == "query"
               and envelope["payload"].get("query_type") == "benchmark_state"
            else f"{self.http_url}/message"
        )
        try:
            resp = _requests.post(endpoint, json=envelope, timeout=15)
            resp.raise_for_status()
            return resp.json()
        except Exception as exc:
            raise RuntimeError(f"HTTP send failed ({endpoint}): {exc}") from exc

    # ── Async transport ───────────────────────────────────────────────────────

    async def _async_send(
        self,
        message_type: str,
        payload: dict[str, Any],
        confidence: float,
        shannon_H: float,
    ) -> dict[str, Any]:
        if self._writer is None or self._reader is None:
            raise RuntimeError(
                "Not connected. Call await async_connect() first."
            )
        envelope = self._build_envelope(
            message_type, payload, confidence, shannon_H
        )
        data = (json.dumps(envelope) + "\n").encode()
        self._writer.write(data)
        await self._writer.drain()
        raw = await asyncio.wait_for(self._reader.readline(), timeout=15.0)
        return json.loads(raw.decode().strip())

    # ── Background receive thread ─────────────────────────────────────────────

    def _recv_loop(self) -> None:
        """
        Continuously reads messages from the gate (broadcasts, ping, etc.)
        and dispatches them to registered callbacks.
        """
        buf = b""
        while self._connected and self._sock is not None:
            try:
                chunk = self._sock.recv(RECV_BUFFER)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line.decode())
                    except json.JSONDecodeError:
                        continue
                    # Dispatch to callbacks (skip gate_response — already read synchronously)
                    if msg.get("type") not in ("gate_response", "ping"):
                        for cb in self._callbacks:
                            try:
                                cb(msg)
                            except Exception as exc:
                                print(
                                    f"[agent_protocol] callback error: {exc}",
                                    file=sys.stderr,
                                )
            except OSError:
                break
        self._connected = False

    # ─────────────────────────────────────────────────────────────────────────
    # repr
    # ─────────────────────────────────────────────────────────────────────────

    def __repr__(self) -> str:
        return (
            f"AgentClient(agent_id={self.agent_id!r}, "
            f"task_id={self.task_id!r}, "
            f"mode={self.mode!r}, "
            f"connected={self._connected})"
        )


# ── Convenience factory functions ─────────────────────────────────────────────

def local_client(agent_id: str, task_id: str) -> AgentClient:
    """Create a connected local (socket) client."""
    return AgentClient(agent_id, task_id, mode="socket").connect()


def cloud_client(
    agent_id: str,
    task_id: str,
    http_url: str = DEFAULT_HTTP_URL,
) -> AgentClient:
    """Create a cloud (HTTP) client. No connect() call needed."""
    return AgentClient(agent_id, task_id, mode="http", http_url=http_url)


def paste_bridge(agent_id: str, task_id: str) -> None:
    """
    Interactive CLI paste bridge for cloud agents that can't POST directly.

    LP pastes agent output → bridge computes entropy → forwards to gate.
    Launch with:  python agent_protocol.py paste <agent_id> <task_id>
    """
    print(f"Paste Bridge — {agent_id} → Shannon Gate")
    print("Paste agent output and press Ctrl+D (macOS) to submit. Ctrl+C to quit.\n")

    client = AgentClient(agent_id, task_id, mode="socket")
    try:
        client.connect()
    except ConnectionError as exc:
        print(f"ERROR: {exc}")
        sys.exit(1)

    while True:
        print("─" * 60)
        print("Paste output (Ctrl+D to submit, Ctrl+C to quit):")
        lines: list[str] = []
        try:
            while True:
                try:
                    line = input()
                    lines.append(line)
                except EOFError:
                    break
        except KeyboardInterrupt:
            print("\nExiting paste bridge.")
            break

        text = "\n".join(lines).strip()
        if not text:
            continue

        print(f"\nComputed H = {_token_entropy(text):.3f} bits")
        print("Confidence [0-1] (Enter for 0.8): ", end="", flush=True)
        try:
            conf_str = input().strip()
            conf = float(conf_str) if conf_str else 0.8
        except (ValueError, EOFError):
            conf = 0.8

        payload = {"output": text, "source": "paste_bridge"}
        try:
            decision = client.send_result(payload, confidence=conf)
            print(f"\nGate decision: {decision.get('decision','?').upper()}")
            print(f"  gate_H = {decision.get('gate_H', '?'):.3f} bits")
            if decision.get("reasons"):
                print(f"  reasons = {decision['reasons']}")
        except Exception as exc:
            print(f"Send error: {exc}")

    client.close()


# ── CLI entry point ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(
        description="FlexAIDdS agent_protocol.py utilities",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Commands:
  paste <agent_id> <task_id>   Interactive paste bridge (cloud agent proxy)
  test  <agent_id> <task_id>   Send a test status message and print gate response
  state <task_id>              Query and print current benchmark state
""",
    )
    p.add_argument("command", choices=["paste", "test", "state"])
    p.add_argument("agent_id", nargs="?", default="local_test")
    p.add_argument("task_id", nargs="?", default="debug")
    args = p.parse_args()

    if args.command == "paste":
        paste_bridge(args.agent_id, args.task_id)

    elif args.command == "test":
        print(f"Sending test message as '{args.agent_id}'…")
        try:
            with AgentClient(args.agent_id, args.task_id) as c:
                resp = c.send_status(
                    "Test message from agent_protocol CLI",
                    {"version": "1.0", "test": True},
                )
                print(f"Gate response: {json.dumps(resp, indent=2)}")
        except Exception as exc:
            print(f"ERROR: {exc}")
            sys.exit(1)

    elif args.command == "state":
        try:
            c = AgentClient("local_test", args.agent_id, mode="socket")
            c.connect()
            state = c.query_benchmark_state()
            print(json.dumps(state, indent=2))
            c.close()
        except Exception as exc:
            print(f"ERROR: {exc}")
            sys.exit(1)
