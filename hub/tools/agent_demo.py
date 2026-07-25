#!/usr/bin/env python3
"""
tools/agent_demo.py — short-lived AgentClient against the live gate

Registers as ``science``, sends a status line, optionally an approval_needed,
then exits. Used by ``./scripts/shannon agent-demo``.

Usage
-----
  PYTHONPATH=hub python3 hub/tools/agent_demo.py
  PYTHONPATH=hub python3 hub/tools/agent_demo.py --ask

Exit codes
----------
  0  ok
  1  gate offline (no /tmp/shannon.sock) or client error
"""

from __future__ import annotations

import os
import sys
import time

SOCKET_PATH = "/tmp/shannon.sock"


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    want_ask = "--ask" in argv

    if not os.path.exists(SOCKET_PATH):
        print("gate offline: no /tmp/shannon.sock", file=sys.stderr)
        return 1

    # Prefer hub/ on sys.path when launched from scripts/shannon.
    hub_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if hub_root not in sys.path:
        sys.path.insert(0, hub_root)

    from agent_protocol import AgentClient

    task_id = f"agent_demo_{int(time.time())}"
    try:
        with AgentClient("science", task_id) as c:
            c.send_status("agent-demo: science online", details={"demo": True})
            print("ok status sent as science")
            if want_ask:
                reply = c.send_approval_needed(
                    "agent-demo: approve short-lived science probe?",
                    details={"source": "agent_demo"},
                )
                print(f"ok approval_needed sent: {reply.get('decision', reply)}")
    except ConnectionError as exc:
        print(f"gate offline: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — surface any client/gate failure clearly
        print(f"agent-demo failed: {exc}", file=sys.stderr)
        return 1

    print("agent-demo done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
