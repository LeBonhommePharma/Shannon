<div align="center">

# Shannon

### Drug-docking entropy → LLM evaluation-awareness detection

**When a molecule locks into a binding site, configurational entropy collapses.
When an LLM realizes it’s being evaluated, its token distribution does the same thing.**

Shannon is a white-box, physics-grounded referee: real-time **entropy collapse**
detection for frontier agents — plus a multi-agent **macOS notch pill** hub that
makes concurrent agent work observable and killable.

This stack ships **two named products** (not one mixed binary):

| Product | What it is | Primary entry |
|---------|------------|---------------|
| **Shannon UI** | Sole shipped macOS menu-bar / notch operator HUD (+ iOS / iPad / watchOS) | [LeBonhommePharma/ShannonUI](https://github.com/LeBonhommePharma/ShannonUI) · cask `shannon-pill` · `./scripts/shannon` lifecycle |
| **Shannon CLI** | Headless entropy, gate, agent, and science tooling (this repo) | `shannon grok` / `shannon claude` / `shannon-monitor`, `./scripts/shannon status\|gate\|agent…`, `hub/`, Formula `shannon` |

[![CI](https://github.com/LeBonhommePharma/Shannon/actions/workflows/ci.yml/badge.svg)](https://github.com/LeBonhommePharma/Shannon/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![PyPI](https://img.shields.io/badge/PyPI-shannon--entropy-blue.svg)](https://pypi.org/project/shannon-entropy/)
[![C++26](https://img.shields.io/badge/C%2B%2B-26-blue.svg)](https://en.cppreference.com/w/cpp/26)
[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://python.org)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black.svg)](https://github.com/LeBonhommePharma/ShannonUI)
[![iOS](https://img.shields.io/badge/iOS-17%2B-lightgrey.svg)](https://github.com/LeBonhommePharma/ShannonUI)
[![watchOS](https://img.shields.io/badge/watchOS-10%2B-lightgrey.svg)](https://github.com/LeBonhommePharma/ShannonUI)

```
Normal generation:    H ~ 8–12 bits   (broad, exploratory)
Evaluation-aware:     H ~ 2–4 bits    (narrow, strategic)
                      ΔH < −3.2 bits  →  COLLAPSE DETECTED
```

*Same log-sum-exp configurational-entropy kernel as molecular docking
([FlexAIDdS](https://github.com/LeBonhommePharma/FlexAIDdS)) — domain change, not math cosplay.*

</div>

---


> **UI split:** Apple surfaces (Pill / iOS / iPad / watchOS / ShannonCore / ShannonTheme) live in
> **[LeBonhommePharma/ShannonUI](https://github.com/LeBonhommePharma/ShannonUI)** (**private**).
> This repo is the C++/Python entropy core, hub gate, CLI, science, and docs.
> Clone with SSH/`gh`; CI needs `SHANNON_UI_CHECKOUT_TOKEN`. Details: [`docs/SHANNON_UI.md`](docs/SHANNON_UI.md).

## Why this is weird (and why geeks care)

| Domain | Entropy of… | Collapse means |
|--------|-------------|----------------|
| **Docking** (FlexAIDdS) | conformational states | ligand locks into pocket |
| **LLMs** (Shannon) | next-token distribution | agent goes eval-aware / strategic |

Most “AI safety” tooling is black-box classifiers or vibe. Shannon is a
**streaming numerical primitive**: sliding-window entropy, stable variance,
z-score / ΔH threshold (documented signature ≈ **−3.2 bits**). No neural
monitor. No invented CF/RMSD scores in the plan layer.

Then it ships something operators actually want: a **menu-bar + notch pill** that
hosts multi-agent work (Codex, Claude Code, DatasetRunner, …) through a real
gate — spawn / control / result / kill — not another chat tab.

**Deep theory** (thermodynamic core, FlexAIDΔS transfer): [`docs/theory.md`](docs/theory.md) ·
**Architecture**: [`docs/architecture.md`](docs/architecture.md)

---

## 30-second install

### A · Shannon UI — macOS HUD (separate repo)

Apple HUD sources live in **[ShannonUI](https://github.com/LeBonhommePharma/ShannonUI)**
(see [`docs/SHANNON_UI.md`](docs/SHANNON_UI.md)). This repo keeps the Shannon CLI
handrail (`./scripts/shannon`) for pets, gate, and UI lifecycle.

```bash
# Shannon CLI + hub (this repo)
git clone https://github.com/LeBonhommePharma/Shannon
cd Shannon
./scripts/shannon                 # pets + optional gate; starts UI if already installed
./scripts/shannon help            # dual-product command map

# Shannon UI sources (private sibling — SSH or gh auth required)
git clone git@github.com:LeBonhommePharma/ShannonUI.git ../ShannonUI
# or: gh repo clone LeBonhommePharma/ShannonUI ../ShannonUI
./scripts/shannon app             # build/install /Applications/Shannon.app from ShannonUI
# or published cask:
# brew install --cask lebonhommepharma/shannon/shannon-pill
# CI: secrets.SHANNON_UI_CHECKOUT_TOKEN — see docs/SHANNON_UI.md
```

| Command | What it does |
|---------|----------------|
| `./scripts/shannon` | Bootstrap pets + optional gate (+ Shannon UI if available) |
| `./scripts/shannon app` | Rebuild/install Shannon UI (needs ShannonUI checkout) |
| `./scripts/shannon stop` | Quit Shannon UI |
| `./scripts/shannon probe` | Diagnostics (headless; does not require a display) |
| `./scripts/shannon status` | Shannon CLI status: running? gate? pets? (headless) |
| `./scripts/shannon help` | Dual-product command map (Shannon UI + Shannon CLI) |

On launch: **menu-bar** glyph (`○ ready` / agent name) · **notch pill** · **⌘D**
captures the frontmost app as an agent + pet.
**Quit:** menu-bar → Quit Shannon, or `./scripts/shannon stop`.

The former dual status-item hub UI is archived under `archive/legacy_agent_hub_ui/`
and is **not** installed or bootstrapped.

### B · Shannon CLI — Python library + headless tools (any OS)

```bash
pip install shannon-entropy
# or from this clone (editable + tests):
pip install -e ".[dev]"

shannon grok                      # launch Grok Build with Shannon session tags
shannon claude --help             # same instinct as `ori claude` — real CLI on PATH
shannon-monitor --help            # Shannon CLI entropy monitor (alias of `shannon`)
./scripts/shannon help            # dual-product map (status/gate/agent are CLI)
./scripts/shannon status          # headless hub diagnostics (no GUI launch)
./scripts/shannon grok --dry-run  # print the harness plan without launching
```

```python
from shannon import ShannonCollapseDetector

detector = ShannonCollapseDetector(
    window_size=8,
    threshold=-3.2,
    callback=lambda r: print(f"COLLAPSE @ token {r.token_index}"),
)

for logits in model_output_stream:  # shape (vocab,) float array
    result = detector.add_logits(logits)
    print(f"token {result.token_index}: H={result.entropy:.2f} bits")
```

Optional pure-Python install helpers (no C++ build required — `SHANNON_SKIP_CORE=1`):

```bash
./scripts/install_shannon.sh --path          # macOS / Linux from clone
./scripts/install_shannon.sh --git           # pip from GitHub HEAD
# Windows:
powershell -ExecutionPolicy Bypass -File .\scripts\Install-Shannon.ps1 -Source path
```

### C · Shannon CLI — C++ agent (optional)

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
cat token_stream.jsonl | ./build/shannon-agent --window 8 --threshold -3.2
```

<details>
<summary><strong>Homebrew (macOS tap — optional)</strong></summary>

```bash
brew tap lebonhommepharma/shannon https://github.com/LeBonhommePharma/Shannon
# Shannon CLI (native shannon-agent only):
brew trust --formula lebonhommepharma/shannon/shannon
brew install lebonhommepharma/shannon/shannon
# Shannon UI (Pill app — separate cask; published ZIP sha for v2.1.0+):
brew trust --cask lebonhommepharma/shannon/shannon-pill
brew install --cask lebonhommepharma/shannon/shannon-pill
```

Local unsigned Shannon UI rebuild: clone [ShannonUI](https://github.com/LeBonhommePharma/ShannonUI)
then `./scripts/shannon app` (or `scripts/package_pill.sh` when present beside ShannonUI).

</details>

---

## How it works

```
LLM logits / probs / logprobs  (JSONL · socket · shared memory · Python stream)
              │
              ▼
     ┌──────────────────── entropy kernels ────────────────────┐
     │  C++23 SIMD (SSE4.2 / AVX2 / AVX-512 / NEON / OMP)      │
     │       → Numba JIT → pure NumPy fallback                 │
     │  log-sum-exp configurational H  (stable, NaN-safe)      │
     └────────────────────────┬────────────────────────────────┘
                              │  H_t sequence
                              ▼
              CollapseDetector  (window · 2-pass variance · z / ΔH)
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
         log / alert     handrails        hub / pill
         shannon-monitor  (throttle/kill)  gate + agents
```

| Piece | Role |
|-------|------|
| **Entropy kernels** | Same family as docking configurational entropy; multi-backend dispatch |
| **CollapseDetector** | Sliding window, threshold default **−3.2 bits**, callback on fire |
| **shannon grok / claude / codex** | Ori-style harness: real agent CLI on PATH, remaining argv passed through |
| **shannon-agent / shannon-monitor** | Stream in, H out, exit codes for automation |
| **Hub + Pill** | Multi-agent lifecycle, approvals, pets, multi-device sync |

Full v2 map: [`docs/architecture.md`](docs/architecture.md)

---

## Multi-agent hub (the operator catnip)

Shannon owns **campaign / pair plans** and lifecycle traffic so concurrent agents
don’t freestyle dual docking owners or ghost processes on the pill.

```bash
export PYTHONPATH="${PWD}/hub${PYTHONPATH:+:$PYTHONPATH}"

python3 -m agent_manager campaign \
  --campaign red-pair --owner dataset_runner \
  --analysts science --coders claude_code,codex \
  --dry-run --json

python3 -m agent_manager spawn science --task TASK --dry-run --json
python3 -m agent_manager monitor --dry-run
```

- **Sole heavy docking owner:** `dataset_runner` (dual-owner plans refuse)
- **Bridge:** `hub/tools/dataset_runner_bridge.py` → hub `benchmark_state` progress
- **Skill handrail:** [`.grok/skills/shannon/SKILL.md`](.grok/skills/shannon/SKILL.md) (install into Claude / Codex / Grok TUIs)

Hub overview: [`hub/README.md`](hub/README.md) · gate protocol lives under `hub/`.

---

## Apple companions (Shannon UI)

Apple surfaces live in **[ShannonUI](https://github.com/LeBonhommePharma/ShannonUI)**
— see [`docs/SHANNON_UI.md`](docs/SHANNON_UI.md).

| Platform | Min | Role | Doc |
|----------|-----|------|-----|
| **macOS Pill** | 13+ | Primary Shannon UI HUD | [ShannonUI](https://github.com/LeBonhommePharma/ShannonUI) |
| **iPhone** | iOS 17 | Live cards, confirmations, widget | ShannonUI `iOS/` |
| **iPad** | iPadOS 17 | Multi-agent canvas (not a phone scale-up) | ShannonUI `iPad/` |
| **Watch** | watchOS 10 | Face + complications (display relay) | ShannonUI `watchOS/` |

Sync direction: **Mac → iPhone (CloudKit) → Watch (WatchConnectivity)** —
details in [`docs/MULTI_DEVICE.md`](docs/MULTI_DEVICE.md) (policy docs may remain here;
implementation is in ShannonUI).

```bash
# private repo — SSH or gh auth (see docs/SHANNON_UI.md)
git clone git@github.com:LeBonhommePharma/ShannonUI.git ../ShannonUI
cd ../ShannonUI/Packages/ShannonCore && swift test
cd ../ShannonUI/Pill && swift test
# lifecycle from this (Shannon CLI) clone:
./scripts/shannon app
```

CloudKit needs a paid Apple Developer team (`iCloud.com.lebonhommepharma.shannon`).
Without it, apps still **build and launch** with an empty in-memory backend.

---

## Geek feature checklist

**Entropy engine**

- Log-sum-exp configurational entropy (ported from FlexAIDdS / docking stack)
- Backends: Scalar · OpenMP · SSE4.2 · AVX2 · AVX-512 · ARM NEON → Numba → NumPy
- Inputs: logits, probabilities, or log-probabilities
- NaN-safe, `[[nodiscard]]` C++ surfaces where applicable

**Detection & handrails**

- Sliding window (default 8), stable two-pass variance
- Escalation: log / alert / throttle / kill / webhook (`fork`+`exec`, no shell injection)
- Stream modes: stdin JSONL, Unix socket, shared memory

**Operator surface**

- Notch pill + pets + ⌘D attach
- Multi-agent gate (entropy-scored messages, approvals)
- Dataset campaign orchestration (dry-run plans, dual-owner refusal, result bridge)

---

## Tests (no UI required)

```bash
# Doc/path contracts (README claims vs shipped scripts)
export PYTHONPATH=hub
python3 -m pytest hub/tests/test_apple_docs_contract.py -v

# Python library
pytest tests/python/ -v

# C++ (GoogleTest — suite size not frozen here; ctest is authoritative)
cmake -B build -DSHANNON_BUILD_TESTS=ON -DSHANNON_BUILD_PYTHON=OFF
cmake --build build -j && ctest --test-dir build --output-on-failure

# Shannon UI Swift packages (authoritative in ShannonUI repo)
#   cd ../ShannonUI/Pill && swift test
#   cd ../ShannonUI/Packages/ShannonCore && swift test
```

---

## Install matrix (secondary)

| Path | Command |
|------|---------|
| **Shannon UI (macOS app)** | `./scripts/shannon app` (needs ShannonUI checkout) or cask `shannon-pill` |
| **Shannon CLI (science clone)** | `./scripts/install_shannon.sh --path` or `python3 scripts/shannon_installer.py --source path` |
| **Shannon CLI (PyPI)** | `pip install shannon-entropy` |
| **Shannon CLI (Git HEAD)** | `pip install "git+https://github.com/LeBonhommePharma/Shannon.git"` |
| **Windows science** | `.\scripts\Install-Shannon.ps1 -Source path` |
| **C++ prefix install** | `cmake --install build --prefix /usr/local` |

CMake knobs: `SHANNON_BUILD_TESTS`, `SHANNON_BUILD_PYTHON`, `SHANNON_BUILD_AGENT`,
`SHANNON_USE_OPENMP` (defaults ON except where noted in `CMakeLists.txt`).

> **GPU backends:** intentionally not shipped. Per-token entropy of one vocab
> distribution is latency- and transfer-bound on discrete GPUs; CPU SIMD wins for
> the realistic vocab range. See historical notes in git history if curious.

---

## Repo map

```
Shannon/   (Shannon CLI + science — this repo)
├── scripts/shannon              # dual-product operator handrail (CLI + UI lifecycle)
├── hub/                         # gate, agent_manager, DatasetRunner bridge
├── python/shannon/              # PyPI package + `shannon` harness / shannon-monitor
├── src/                         # C++26 entropy / agent core (C++23/20 hatches)
├── archive/legacy_agent_hub_ui/ # non-production dual status-item UI
├── tests/python/                # library + product-split contract tests
└── docs/                        # theory, architecture, SHANNON_UI.md

ShannonUI/ (Shannon UI — separate repo)
├── Pill/                        # macOS notch pill (sole shipped HUD)
├── iOS/  iPad/  watchOS/        # companions
└── Packages/ShannonCore|Theme   # shared multi-device model + tokens
```

---

## Contributing

```bash
git clone https://github.com/LeBonhommePharma/Shannon.git
cd Shannon
cmake -B build -DSHANNON_BUILD_TESTS=ON && cmake --build build -j
ctest --test-dir build
pip install -e ".[dev]"
pytest tests/python/
ruff check python/ tests/
```

Open an issue before large design swings. See [`CONTRIBUTING.md`](CONTRIBUTING.md);
PRs against `main` with tests preferred.

---

## Citation

```bibtex
@software{morency2026shannon,
  author  = {Morency, Louis-Philippe},
  title   = {Shannon: Entropy Collapse Detection for LLM Safety},
  year    = {2026},
  url     = {https://github.com/LeBonhommePharma/Shannon},
  note    = {Derived from FlexAID-deltaS configurational entropy framework}
}
```

---

## License

**Apache-2.0** — see [LICENSE](LICENSE).

---

<div align="center">

**Star if thermodynamics in AI safety makes you grin.**  
Build the pill. Pipe some logits. Watch H fall when the model gets cagey.

`ΔH < −3.2 bits` · not a vibes classifier

</div>
