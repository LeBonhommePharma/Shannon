# Agent Hub — Architecture Summary

Condensed summary of [`hub/ARCHITECTURE.md`](../ARCHITECTURE.md) (original design
doc) plus notes on security hardening applied during integration into the Shannon
repo.

## What this is

The Agent Hub is a local, macOS-oriented coordination layer that lets several AI
agents (local coding agents, cloud agents such as Codex/Grok, and dataset runner
processes) collaborate on a single machine without stepping on each other or
silently drifting into low-information output. It sits outside the core Shannon
entropy library — it does not link against it and does not change any C++ code.

## Canonical components (`hub/`)

| Path | Role |
|------|------|
| `shannon_gate.py` | Broker/daemon: Unix socket `/tmp/shannon.sock`, optional HTTP, gate decisions, SQLite audit (`~/.shannon/agent_hub.db`) |
| `agent_protocol.py` | Client library for socket / HTTP |
| `credentials.py` | macOS Keychain wrapper for cloud-agent tokens |
| `pet_manager.py` | Per-agent memory under `~/.shannon/pets/<agent_id>/` |
| `system_monitor.py` | CPU/RAM/disk/thermal/battery samples for the HUD |
| `tools/dataset_runner_bridge.py` | Benchmark results → hub `benchmark_state` |
| `agent_manager.py` / `agent_identity.py` | Live registry and identity helpers |
| `AgentHubApp.swift` | **Legacy** menu-bar UI — production HUD is ShannonPill (`Pill/`) |

## Auth hardening (integration)

**`credentials.py`**

- Keychain writes use `-U` with device-only accessibility (never synced).
- Reads/writes retry on `errSecInteractionNotAllowed`, then raise
  `KeychainUnavailableError` — no plaintext fallback.
- Logs never include full credential values (masked last 4 chars only).

**`agent_protocol.py`**

- Credential checks at the send choke point; rate limiting for cloud agents.

**`shannon_gate.py`**

- Peer UID checks on the Unix socket where available.
- HTTP bearer + body HMAC verification when the HTTP endpoint is enabled.

## Tests

Canonical coverage lives in `hub/tests/`. Keychain access is mocked — the real
macOS Keychain is not touched by the suite.

```bash
pytest hub/tests/ -v
```
