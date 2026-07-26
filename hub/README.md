# Shannon Agent Hub

Canonical multi-agent coordination layer for Shannon. **This `hub/` tree is the
only production gate package.** The former `agent_hub/` snapshot has been
removed (stale nested `python/` / `swift/` copies under `hub/` were also dropped).

| Item | Live path |
|------|-----------|
| Gate daemon | `hub/shannon_gate.py` |
| Socket | `/tmp/shannon.sock` |
| Audit DB | `~/.shannon/agent_hub.db` (filename only; not a second package) |
| Tests | `hub/tests/` |
| Identities | `hub/agent_identity.py` |
| Menu-bar / notch HUD | `Pill/` → ShannonPill via `./scripts/shannon` |

`hub/AgentHubApp.swift` is a **legacy** dual status-item Swift UI. Do not launch
it alongside ShannonPill.

## What this package provides

- **Gate daemon** (`shannon_gate.py`) — Unix socket broker, optional HTTP, text-
  entropy / integrity checks, SQLite audit log
- **Client protocol** (`agent_protocol.py`) — agents talk to the gate
- **Credentials** (`credentials.py`) — macOS Keychain; no plaintext secrets on disk
- **Agent manager / identity** (`agent_manager.py`, `agent_identity.py`)
- **Pet memory** (`pet_manager.py`, `pet_*`) under `~/.shannon/pets/`
- **System monitor** (`system_monitor.py`) for HUD resource samples
- **Dataset runner bridge** (`tools/dataset_runner_bridge.py`)
- **Architecture / threat model** (`ARCHITECTURE.md`)

## Layout

```
hub/
├── README.md
├── ARCHITECTURE.md
├── docs/AGENT_HUB.md          — integration summary + auth hardening notes
├── shannon_gate.py            — gate daemon
├── agent_*.py / pet_*.py / …
├── requirements.txt
├── tests/                     — pytest suite (canonical)
├── tools/
├── Pet/                       — pet animation helpers (Swift)
└── AgentHubApp.swift          — legacy HUD (do not ship)
```

## Run tests

```bash
# from repo root
pytest hub/tests/ -v
```

## Related

- Design / threat model: [ARCHITECTURE.md](ARCHITECTURE.md)
- Integration notes: [docs/AGENT_HUB.md](docs/AGENT_HUB.md)
- macOS HUD: [../Pill/README.md](../Pill/README.md)
