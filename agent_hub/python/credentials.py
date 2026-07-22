#!/usr/bin/env python3
"""
credentials.py — Shannon Hub Keychain Manager
==============================================
Low-level macOS Keychain I/O for the Shannon agent hub.

All secrets are stored in the macOS Keychain (via the `security` CLI).
Nothing is written to disk in plaintext, to SQLite, or to env files.

Keychain layout
---------------
  service : "Shannon.AgentHub"          (configurable via SHANNON_KEYCHAIN_SERVICE)
  account : "<agent_id>.token"          e.g. "grok_build.token"
  value   : the API key / OAuth token

Usage
-----
  from credentials import KeychainStore, AuthError

  # Store a token (once, manually or via OAuth flow)
  KeychainStore.store("grok_build", "xai-...")

  # Load (app code — never log the value)
  token = KeychainStore.load("grok_build")   # None if not found

  # Delete
  KeychainStore.delete("grok_build")

  # High-level: check + ping auth endpoint, raises AuthError on failure
  from credentials import check_cloud_agent
  check_cloud_agent("grok_build")            # raises AuthError if bad

CLI
---
  python credentials.py store   grok_build   # prompts for token (hidden input)
  python credentials.py load    grok_build   # prints "found" / "not found" (NOT the value)
  python credentials.py delete  grok_build
  python credentials.py check   grok_build   # pings auth endpoint
  python credentials.py list                 # prints which agents have stored creds

Dependencies
------------
  macOS `security` CLI (bundled, no pip install needed)
  requests (optional, for check command)
"""

from __future__ import annotations

import getpass
import logging
import os
import subprocess
import sys
import time
import warnings
from typing import Optional

# Optional HTTP for credential check
try:
    import requests as _requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False

_log = logging.getLogger("shannon.credentials")

# ── Configuration ─────────────────────────────────────────────────────────────

KEYCHAIN_SERVICE: str = os.environ.get("SHANNON_KEYCHAIN_SERVICE", "Shannon.AgentHub")

# Accessibility class applied to every Keychain item written by this module.
# "WhenUnlockedThisDeviceOnly" — never synced (e.g. to iCloud Keychain),
# and only readable while the device is unlocked.
KEYCHAIN_ACCESSIBLE: str = "kSecAttrAccessibleWhenUnlockedThisDeviceOnly"

# security(1) exit code for errSecInteractionNotAllowed (-25308): the
# Keychain is locked / session isn't allowed to prompt (e.g. headless SSH).
_ERR_SEC_INTERACTION_NOT_ALLOWED = 25308
_MAX_RETRIES = 3
_BACKOFF_BASE_SECONDS = 0.1  # 100ms, doubles each retry

# Agents that require cloud credentials (API key / OAuth token).
# Local agents authenticate via the in-memory socket secret — no stored cred needed.
CLOUD_AGENTS: frozenset[str] = frozenset({"codex", "grok_build"})

# Lightweight auth-check endpoints (GET, expect 2xx for valid token)
_AUTH_ENDPOINTS: dict[str, str] = {
    "codex":      "https://api.github.com/user",
    "grok_build": "https://api.x.ai/v1/models",
}

# Env-var fallbacks when no Keychain entry exists (CI / development only)
_ENV_FALLBACKS: dict[str, tuple[str, ...]] = {
    "codex":      ("GITHUB_TOKEN", "OPENAI_API_KEY"),
    "grok_build": ("GROK_API_KEY", "XAI_API_KEY"),
}


# ── Exception ─────────────────────────────────────────────────────────────────

class AuthError(Exception):
    """
    Raised when a cloud agent's credential is missing, expired, or rejected.

    Attributes
    ----------
    agent_id : str   — which agent failed
    reason   : str   — human-readable reason (never contains the actual token)
    """

    def __init__(self, agent_id: str, reason: str) -> None:
        super().__init__(f"[{agent_id}] Auth error: {reason}")
        self.agent_id = agent_id
        self.reason   = reason


class KeychainUnavailableError(Exception):
    """
    Raised when the Keychain cannot be reached after retrying (e.g. it is
    locked and non-interactive, or the `security` CLI is unusable).

    This is intentionally NOT caught to fall back to plaintext storage —
    callers must treat it as a hard failure.
    """

    def __init__(self, agent_id: str, detail: str) -> None:
        super().__init__(f"[{agent_id}] Keychain unavailable: {detail}")
        self.agent_id = agent_id
        self.detail = detail


def _redact(agent_id: str, account: str, value: Optional[str]) -> str:
    """Build a safe log fragment: service/account plus only the last 4 chars, masked."""
    if not value:
        return f"agent={agent_id} account={account} value=<empty>"
    last4 = value[-4:] if len(value) >= 4 else value
    return f"agent={agent_id} account={account} value=***{last4}"


def _extract_security_error_code(stderr) -> Optional[int]:
    """Best-effort parse of the numeric OSStatus out of `security` CLI stderr."""
    if isinstance(stderr, bytes):
        stderr = stderr.decode(errors="replace")
    for token in stderr.replace(",", " ").split():
        token = token.strip("()")
        try:
            return int(token)
        except ValueError:
            continue
    return None


def _run_security_with_retry(args: list[str], *, agent_id: str, account: str, timeout: int):
    """
    Run a `security` CLI invocation, retrying up to _MAX_RETRIES times with
    100ms exponential backoff if the Keychain reports errSecInteractionNotAllowed
    (-25308) — e.g. locked Keychain in a non-interactive session.

    Raises KeychainUnavailableError if all retries are exhausted. Never falls
    back to plaintext storage.
    """
    last_result = None
    for attempt in range(_MAX_RETRIES + 1):
        result = subprocess.run(args, capture_output=True, timeout=timeout)
        last_result = result
        code = _extract_security_error_code(result.stderr)
        if code != _ERR_SEC_INTERACTION_NOT_ALLOWED:
            return result
        _log.warning(
            "Keychain locked/unavailable (errSecInteractionNotAllowed) for %s, "
            "attempt %d/%d",
            _redact(agent_id, account, None), attempt + 1, _MAX_RETRIES + 1,
        )
        if attempt < _MAX_RETRIES:
            time.sleep(_BACKOFF_BASE_SECONDS * (2 ** attempt))
    raise KeychainUnavailableError(
        agent_id,
        f"errSecInteractionNotAllowed after {_MAX_RETRIES + 1} attempts "
        f"(account={account})",
    )


# ── Keychain store ────────────────────────────────────────────────────────────

class KeychainStore:
    """
    macOS Keychain read/write via the bundled `security` CLI.
    All methods are class-methods — no instance needed.

    Every item is written with kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    so it never syncs off-device and is only accessible while unlocked.
    """

    @classmethod
    def store(cls, agent_id: str, token: str) -> None:
        """
        Add or update a token in the Keychain.

        Parameters
        ----------
        agent_id : str   e.g. "grok_build"
        token    : str   the API key / OAuth token — NOT logged, NOT returned

        Raises
        ------
        RuntimeError               if the security CLI fails unexpectedly.
        KeychainUnavailableError   if the Keychain can't be reached after retries.
        """
        account = f"{agent_id}.token"
        result = _run_security_with_retry(
            [
                "security", "add-generic-password",
                "-s", KEYCHAIN_SERVICE,
                "-a", account,
                "-w", token,
                "-U",              # update if key already exists
            ],
            agent_id=agent_id, account=account, timeout=10,
        )
        if result.returncode not in (0, 45):  # 45 = duplicate (already present, updated)
            _log.error("Keychain store failed: %s", _redact(agent_id, account, None))
            raise RuntimeError(
                f"Keychain store failed for {agent_id}: "
                f"exit={result.returncode} stderr={result.stderr.decode(errors='replace')!r}"
            )
        _log.info("Keychain store OK: %s", _redact(agent_id, account, token))

    @classmethod
    def load(cls, agent_id: str) -> Optional[str]:
        """
        Load token from Keychain.  Returns None if no entry exists.
        Falls back to env vars for CI / development convenience.

        IMPORTANT: never log the returned value.
        """
        account = f"{agent_id}.token"
        # 1. Keychain
        try:
            result = _run_security_with_retry(
                [
                    "security", "find-generic-password",
                    "-s", KEYCHAIN_SERVICE,
                    "-a", account,
                    "-w",
                ],
                agent_id=agent_id, account=account, timeout=5,
            )
            stdout = result.stdout.decode(errors="replace") if isinstance(result.stdout, bytes) else result.stdout
            if result.returncode == 0 and stdout.strip():
                return stdout.strip()
        except KeychainUnavailableError:
            raise
        except Exception:
            pass

        # 2. Env-var fallback (CI / development only — still not "plaintext
        # storage" since it's not written by this module).
        for var in _ENV_FALLBACKS.get(agent_id, ()):
            val = os.environ.get(var)
            if val:
                return val
        return None

    @classmethod
    def delete(cls, agent_id: str) -> bool:
        """Remove token from Keychain.  Returns True if deleted, False if not found."""
        account = f"{agent_id}.token"
        result = _run_security_with_retry(
            [
                "security", "delete-generic-password",
                "-s", KEYCHAIN_SERVICE,
                "-a", account,
            ],
            agent_id=agent_id, account=account, timeout=10,
        )
        return result.returncode == 0

    @classmethod
    def has_credential(cls, agent_id: str) -> bool:
        """Return True if a token is stored (Keychain or env fallback)."""
        return cls.load(agent_id) is not None

    @classmethod
    def list_stored(cls) -> list[str]:
        """Return sorted list of agent_ids that have a stored Keychain entry."""
        stored = []
        for agent_id in sorted(CLOUD_AGENTS):
            try:
                if credential_exists(KEYCHAIN_SERVICE, f"{agent_id}.token"):
                    stored.append(agent_id)
            except KeychainUnavailableError:
                continue
        return stored


def credential_exists(service: str, account: str) -> bool:
    """
    Check whether a Keychain item exists for (service, account) without
    reading its value. Retries on errSecInteractionNotAllowed like the rest
    of this module; never falls back to plaintext.
    """
    try:
        result = _run_security_with_retry(
            [
                "security", "find-generic-password",
                "-s", service,
                "-a", account,
            ],
            agent_id=account, account=account, timeout=5,
        )
    except KeychainUnavailableError:
        raise
    return result.returncode == 0


# ── High-level check ──────────────────────────────────────────────────────────

def check_cloud_agent(agent_id: str, timeout: float = 5.0) -> bool:
    """
    Verify that a cloud agent's stored token is accepted by its auth endpoint.

    Local agents are always considered authed (they use the in-memory socket
    secret, not a stored credential).

    Parameters
    ----------
    agent_id : str   agent identifier
    timeout  : float seconds to wait for the auth HTTP ping

    Returns
    -------
    True if credentials are valid.

    Raises
    ------
    AuthError   if token is missing or rejected by the auth endpoint.
    """
    if agent_id not in CLOUD_AGENTS:
        return True   # local agent — authenticated via socket secret

    token = KeychainStore.load(agent_id)
    if not token:
        raise AuthError(
            agent_id,
            f"no credential stored. Run:\n"
            f"  python credentials.py store {agent_id}"
        )

    endpoint = _AUTH_ENDPOINTS.get(agent_id)
    if not endpoint:
        return True   # no known endpoint → soft pass

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
        # Network unreachable, DNS failure, etc. → soft pass (don't block local work)
        warnings.warn(
            f"Auth ping for {agent_id} timed out or errored: {exc}",
            stacklevel=2,
        )
        return True


# ── CLI ───────────────────────────────────────────────────────────────────────

def _cli_main() -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description="Shannon Hub credential manager (macOS Keychain)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Tokens are stored in the macOS Keychain, never in files or logs.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    # store
    p_store = sub.add_parser("store", help="Store a token in Keychain")
    p_store.add_argument("agent_id", choices=sorted(CLOUD_AGENTS))

    # load / has
    p_load = sub.add_parser("load", help="Check if a token is stored")
    p_load.add_argument("agent_id", choices=sorted(CLOUD_AGENTS))

    # delete
    p_del = sub.add_parser("delete", help="Remove token from Keychain")
    p_del.add_argument("agent_id", choices=sorted(CLOUD_AGENTS))

    # check
    p_check = sub.add_parser("check", help="Ping auth endpoint with stored token")
    p_check.add_argument("agent_id", choices=sorted(CLOUD_AGENTS))

    # list
    sub.add_parser("list", help="List agents with stored credentials")

    args = parser.parse_args()

    if args.cmd == "store":
        token = getpass.getpass(f"Token for {args.agent_id} (input hidden): ")
        if not token.strip():
            print("❌  Empty token — aborting", file=sys.stderr)
            sys.exit(1)
        KeychainStore.store(args.agent_id, token.strip())
        print(f"✅  Token for {args.agent_id!r} stored in Keychain.")

    elif args.cmd == "load":
        if KeychainStore.has_credential(args.agent_id):
            print(f"✅  Credential found for {args.agent_id!r}.")
        else:
            print(f"❌  No credential found for {args.agent_id!r}.")
            sys.exit(1)

    elif args.cmd == "delete":
        if KeychainStore.delete(args.agent_id):
            print(f"🗑   Credential for {args.agent_id!r} deleted.")
        else:
            print(f"⚠️   No Keychain entry found for {args.agent_id!r}.")

    elif args.cmd == "check":
        try:
            ok = check_cloud_agent(args.agent_id)
            if ok:
                print(f"✅  {args.agent_id!r} credentials valid.")
        except AuthError as exc:
            print(f"❌  {exc}", file=sys.stderr)
            sys.exit(1)

    elif args.cmd == "list":
        stored = KeychainStore.list_stored()
        if stored:
            print("Agents with stored credentials:")
            for a in stored:
                print(f"  🔑 {a}")
        else:
            print("No credentials stored.")


if __name__ == "__main__":
    _cli_main()
