<div align="center">

# Shannon

### Drug-docking entropy → LLM evaluation-awareness detection

**When a molecule locks into a binding site, configurational entropy collapses.
When an LLM realizes it’s being evaluated, its token distribution does the same thing.**

Shannon is a white-box, physics-grounded referee: real-time **entropy collapse**
detection for frontier agents — plus a multi-agent **macOS notch pill** hub that
makes concurrent agent work observable and killable.

[![CI](https://github.com/LeBonhommePharma/Shannon/actions/workflows/ci.yml/badge.svg)](https://github.com/LeBonhommePharma/Shannon/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![PyPI](https://img.shields.io/badge/PyPI-shannon--entropy-blue.svg)](https://pypi.org/project/shannon-entropy/)
[![C++20](https://img.shields.io/badge/C%2B%2B-20-blue.svg)](https://en.cppreference.com/w/cpp/20)
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
> **[LeBonhommePharma/ShannonUI](https://github.com/LeBonhommePharma/ShannonUI)**.
> This repo is the C++/Python entropy core, hub gate, CLI, science, and docs.
> Details: [`docs/SHANNON_UI.md`](docs/SHANNON_UI.md).

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

### A · macOS hub (primary operator path)

```bash
git clone https://github.com/LeBonhommePharma/Shannon
cd Shannon
./scripts/shannon                 # pets + install /Applications/Shannon.app + start
# Later:
git pull && ./scripts/shannon update
```

| Command | What it does |
|---------|----------------|
| `./scripts/shannon` | Bootstrap pets + app |
| `./scripts/shannon update` | Rebuild + reinstall from this clone |
| `./scripts/shannon stop` | Quit the pill |
| `./scripts/shannon probe` | Diagnostics |
| `./scripts/shannon status` | Running? gate? pets? |
| `./scripts/shannon help` | Full command list |

On launch: **menu-bar** glyph (`○ ready` / agent name) · **notch pill** (or
menu-bar capsule) · **⌘D** captures the frontmost app as an agent + pet.
**Quit:** menu-bar → Quit Shannon, or `./scripts/shannon stop`.

Pill deep-dive: [`Pill/README.md`](Pill/README.md) · honest gaps: [`Pill/BLOCKED.md`](Pill/BLOCKED.md)

### B · Python library (any OS)

```bash
pip install shannon-entropy
# or from this clone (editable + tests):
pip install -e ".[dev]"

shannon-monitor --help
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

### C · C++ agent (optional)

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
cat token_stream.jsonl | ./build/shannon-agent --window 8 --threshold -3.2
```

<details>
<summary><strong>Homebrew (macOS tap — optional)</strong></summary>

```bash
brew tap lebonhommepharma/shannon https://github.com/LeBonhommePharma/Shannon
brew trust --formula lebonhommepharma/shannon/shannon
brew install lebonhommepharma/shannon/shannon    # shannon-agent CLI
# Cask (published ZIP sha for v2.1.0+):
brew trust --cask lebonhommepharma/shannon/shannon-pill
brew install --cask lebonhommepharma/shannon/shannon-pill
```

Local unsigned rebuild: `./scripts/package_pill.sh --install`

</details>

---

## How it works

```
LLM logits / probs / logprobs  (JSONL · socket · shared memory · Python stream)
              │
              ▼
     ┌──────────────────── entropy kernels ────────────────────┐
     │  C++20 SIMD (SSE4.2 / AVX2 / AVX-512 / NEON / OMP)      │
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

## Apple companions

| Platform | Min | Role | Doc |
|----------|-----|------|-----|
| **macOS Pill** | 13+ | Primary hub UI | [`Pill/README.md`](Pill/README.md) |
| **iPhone** | iOS 17 | Live cards, confirmations, widget | [`iOS/README.md`](iOS/README.md) |
| **iPad** | iPadOS 17 | Multi-agent canvas (not a phone scale-up) | [`iPad/README.md`](iPad/README.md) |
| **Watch** | watchOS 10 | Face + complications (display relay) | [`watchOS/README.md`](watchOS/README.md) |

Sync direction: **Mac → iPhone (CloudKit) → Watch (WatchConnectivity)** —
details in [`docs/MULTI_DEVICE.md`](docs/MULTI_DEVICE.md).

```bash
# Shared model (no signing required)
cd Packages/ShannonCore && swift test

# Multi-OS health (macOS always; simulators when Xcode allows)
./scripts/test_apple_platforms.sh --quick
./scripts/validate_xcodeprojs.sh
open Pill/ShannonPill.xcodeproj
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

# Swift packages (swift test is authoritative)
cd Pill && swift test
cd Packages/ShannonCore && swift test
cd Packages/ShannonTheme && swift test
```

---

## Install matrix (secondary)

| Path | Command |
|------|---------|
| **macOS app** | `./scripts/shannon` / `./scripts/shannon update` |
| **Science (clone)** | `./scripts/install_shannon.sh --path` or `python3 scripts/shannon_installer.py --source path` |
| **Science (PyPI)** | `pip install shannon-entropy` |
| **Science (Git HEAD)** | `pip install "git+https://github.com/LeBonhommePharma/Shannon.git"` |
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
Shannon/
├── scripts/shannon              # primary macOS operator handrail
├── Pill/                        # macOS notch pill (Swift)
├── iOS/  iPad/  watchOS/        # companions
├── Packages/ShannonCore|Theme   # shared multi-device model + tokens
├── hub/                         # gate, agent_manager, DatasetRunner bridge
├── python/shannon/              # PyPI package + shannon-monitor
├── src/                         # C++20 entropy / agent core
├── tests/python/                # library tests
└── docs/                        # theory, architecture, multi-device
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
