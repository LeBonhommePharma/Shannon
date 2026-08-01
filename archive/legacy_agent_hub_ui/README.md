# Archived: legacy dual status-item hub UI

**Not part of any production product.** Kept only as historical reference.

| Path (here) | Former production path | Role |
|-------------|------------------------|------|
| `AgentHubApp.swift` | `hub/AgentHubApp.swift` | Dual menu-bar status-item AppKit/SwiftUI app |
| `Pet/*` | `hub/Pet/*` | Canvas pet drawing helpers used only by that app |

## Production products (current)

| Product | Tree / entry | Role |
|---------|--------------|------|
| **Shannon UI** | [ShannonUI](https://github.com/LeBonhommePharma/ShannonUI) Pill → `/Applications/Shannon.app` | Sole shipped menu-bar / notch operator HUD |
| **Shannon CLI** | this repo: `python/shannon/`, `hub/*.py`, `shannon-agent`, Formula | Headless entropy, gate, and agent tooling |

Do **not** wire this archive into install, bootstrap, Homebrew, package scripts,
or UI build targets. Production pet rendering lives under `Pill/Sources/PillCore/`
(ported from these sources). Production gate code remains under `hub/` (Python only).
