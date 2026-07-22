# Agent Hub — Architecture Summary

This is a condensed summary of `agent_hub/ARCHITECTURE.md` (the original design
doc, copied verbatim into this directory) plus notes on the security hardening
applied during integration into the Shannon repo.

> Note: the task that produced this integration originally expected a second
> source directory of hand-written docs (`README.md`, `docs/*.md`,
> `credentials_setup.py`) to be copied in. That directory did not exist on the
> machine performing the integration, so this file was written fresh instead,
> based only on the real `ARCHITECTURE.md` and the actual `.py`/`.swift` source
> files that were integrated — nothing here is fabricated or copied from a
> source that couldn't be verified.

## What this is

The Agent Hub is a local, macOS-only coordination layer that lets several AI
agents (a local coding agent, cloud agents such as Codex/Grok, and dataset
runner processes) collaborate on a single machine without stepping on each
other or silently drifting into low-information ("hallucinated") output. It
sits entirely outside the core Shannon entropy library — it does not link
against it and does not change any C++/CUDA code.

## Components (as copied into `agent_hub/`)

- **`swift/AgentHubApp.swift`** — a macOS menu-bar "pill" UI that shows live
  agent status, system resource usage, and recent hub activity.
- **`python/shannon_gate.py`** — the central broker/daemon. Runs a Unix
  domain socket (`/tmp/shannon.sock`) for local agents and an optional HTTP
  endpoint (`127.0.0.1:8765`, via `aiohttp`) for cloud agents. Computes
  Shannon-entropy-based "gate" decisions (pass / flagged / blocked) on
  incoming agent messages and keeps a SQLite audit log.
- **`python/agent_protocol.py`** — the client library agents use to talk to
  the gate, over either the Unix socket or HTTP.
- **`python/credentials.py`** — thin wrapper around the macOS `security` CLI
  for storing/loading cloud-agent API tokens in the Keychain.
- **`python/pet_manager.py`** — per-agent persistent "memory" under
  `~/.shannon/pets/<agent_id>/` (memory.md, history.jsonl, state.json),
  used for divergence checks between an agent's current claim and its past
  results.
- **`python/system_monitor.py`** — polls CPU/RAM/disk/thermal/battery and
  writes to the shared SQLite DB for the Swift HUD to display.
- **`python/tools/dataset_runner_bridge.py`** — a thin adapter that watches
  a results directory for benchmark output files and forwards progress into
  the hub's SQLite `benchmark_state` table. This is the only file that knows
  about domain-specific result formats; the hub core does not.

## Auth hardening applied during this integration

**`credentials.py`**
- Every Keychain item is written with `-U` plus an explicit accessibility
  policy note (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never synced,
  only readable while the device is unlocked).
- Reads/writes retry up to 3 times with 100ms exponential backoff on
  `errSecInteractionNotAllowed` (locked Keychain in a non-interactive
  session), then raise `KeychainUnavailableError` — there is no silent
  fallback to plaintext storage.
- Added `credential_exists(service, account) -> bool`.
- Logging never includes credential values — only `agent_id`, `account`,
  and the last 4 characters, masked (`***1234`).

**`agent_protocol.py`**
- `@require_credentials` decorator wraps the single outgoing-request choke
  point (`AgentClient._send`), so every message a cloud agent sends first
  passes `CredentialManager.credential_check()`.
- Added `CredentialManager.rotate_if_needed()`, which raises if a token's
  `expires_at` is within 5 minutes, forcing a refresh before the request
  goes out.
- Added a per-agent `RateLimiter` (60 requests/minute, sliding window);
  breaching it raises `RateLimitExceeded`, which carries `status_code = 429`
  and a `Retry-After` header value.

**`shannon_gate.py`**
- Unix socket connections are checked against a UID allowlist
  (`_peer_uid_allowed`) using `SO_PEERCRED` (Linux) / `LOCAL_PEERCRED`
  (macOS/BSD) so only processes running as the same local user as the gate
  daemon can connect; other UIDs are rejected before the registration
  handshake even runs.
- The HTTP endpoint requires a `Bearer` token (sourced from the Keychain via
  `SHANNON_GATE_BEARER_TOKEN`) on every request — mismatches return 401.
- Every HTTP request body must carry a valid `X-Shannon-Sig: sha256=<hex>`
  HMAC-SHA256 signature over the raw body, verified in constant time
  (`hmac.compare_digest`) — signature failures return 401.

## Tests

`agent_hub/python/tests/` has pytest coverage for all six Python files
(`credentials.py`, `agent_protocol.py`, `shannon_gate.py`, `pet_manager.py`,
`system_monitor.py`, `tools/dataset_runner_bridge.py`). All Keychain access is
mocked with `unittest.mock.patch` — the real macOS Keychain is never touched
by the test suite. See `agent_hub/README.md` for the latest pass/fail count
and a screenshot of the run.
