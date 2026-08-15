# Shannon Agent Hub (Shannon CLI)

Canonical multi-agent coordination layer for **Shannon CLI**. **This `hub/` tree
is the only production gate package** (Python). The former `agent_hub/` snapshot
has been removed (stale nested `python/` / `swift/` copies under `hub/` were
also dropped). The legacy dual status-item Swift UI was archived out of this
tree to `archive/legacy_agent_hub_ui/` and is **not** part of Shannon UI or
Shannon CLI production paths.

| Item | Live path | Product |
|------|-----------|---------|
| Gate daemon | `hub/shannon_gate.py` | Shannon CLI |
| Agent manager | `hub/agent_manager.py` (`./scripts/shannon agent`) | Shannon CLI |
| Socket | `/tmp/shannon.sock` | Shannon CLI |
| Audit DB | `~/.shannon/agent_hub.db` (filename only; not a second package) | Shannon CLI |
| Tests | `hub/tests/` | Shannon CLI |
| Identities | `hub/agent_identity.py` | Shannon CLI |
| Menu-bar / notch HUD | [ShannonUI](https://github.com/LeBonhommePharma/ShannonUI) Pill → ShannonPill via `./scripts/shannon` | **Shannon UI** (only shipped HUD; separate repo) |

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
├── shannon_gate.py            — Shannon CLI gate daemon
├── agent_*.py / pet_*.py / …
├── requirements.txt
├── tests/                     — pytest suite (canonical)
└── tools/
```

Archived (non-production): `archive/legacy_agent_hub_ui/` (former dual status-item
Swift UI + Pet Canvas helpers). Production pet rendering lives in Shannon UI:
[LeBonhommePharma/ShannonUI](https://github.com/LeBonhommePharma/ShannonUI)
`Pill/Sources/PillCore/` (not this CLI monorepo).

## Run tests

```bash
# from repo root
pytest hub/tests/ -v
```

## Related

- Design / threat model: [ARCHITECTURE.md](ARCHITECTURE.md)
- Integration notes: [docs/AGENT_HUB.md](docs/AGENT_HUB.md)
- Shannon UI (macOS HUD): [LeBonhommePharma/ShannonUI](https://github.com/LeBonhommePharma/ShannonUI) · [docs/SHANNON_UI.md](../docs/SHANNON_UI.md)
- Shannon CLI entropy monitor: `shannon-monitor --help`
- Ori-style agent harness: `shannon grok` / `shannon claude` / `shannon codex`
