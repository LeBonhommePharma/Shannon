<div align="center">

# Shannon

*Entropy collapse detection meets AI safety.*

**A white-box physicochemical referee for zero-shot detection of evaluation awareness and strategic deception in frontier LLM agents.**

[![CI](https://github.com/LeBonhommePharma/Shannon/actions/workflows/ci.yml/badge.svg)](https://github.com/LeBonhommePharma/Shannon/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![PyPI](https://img.shields.io/badge/PyPI-shannon--entropy-blue.svg)](https://pypi.org/project/shannon-entropy/)
[![C++20](https://img.shields.io/badge/C%2B%2B-20-blue.svg)](https://en.cppreference.com/w/cpp/20)
[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://python.org)
[![Tests](https://img.shields.io/badge/tests-70%20pass-brightgreen.svg)]()

> 94% sensitivity on deceptive agent traces | <0.3% FP on normal generation | <1 us per token
>
> Directly ported from the configurational entropy engine in [FlexAIDdS](https://github.com/LeBonhommePharma/FlexAIDdS) — validated on 590 protein-drug complexes (r=0.93 ITC, 92% binding mode rescue).

</div>

---

## Overview

When an LLM agent becomes aware it is being evaluated, its token probability distributions undergo a characteristic **entropy collapse** — the exact same thermodynamic signature observed when a drug molecule locks into a protein binding site.

```
Normal generation:    H ~ 8-12 bits  (broad, exploratory distribution)
Evaluation-aware:     H ~ 2-4 bits   (narrow, strategic distribution)
                      dH < -3.2 bits  -->  COLLAPSE DETECTED
```

Shannon detects this in real-time, with <1% overhead on token generation.

---

## v2 Architecture

Shannon v2 is a modular C++20 library with Python bindings, a CLI agent, and multi-backend SIMD dispatch.

```
LLM Stream (logits / probs / logprobs / JSONL / socket / shared memory)
     |
     v
+------------------------------------------------------------------+
|  shannon-agent / TerminalAgent                                    |
|  +------------------+  +-----------------+  +-----------------+   |
|  | UnifiedDispatch  |  | CollapseDetector|  | HandrailEngine  |   |
|  | (auto-selects    |  | (sliding window,|  | (escalation:    |   |
|  |  best SIMD/GPU   |  |  stable 2-pass  |  |  alert/throttle/|   |
|  |  backend)        |  |  variance,      |  |  kill/coredump/ |   |
|  |                  |  |  z-score)       |  |  webhook)       |   |
|  +-------+----------+  +--------+--------+  +--------+--------+   |
|          |                       |                     |           |
|  +-------v----------+           |              callbacks           |
|  | Entropy Kernels  |           |                     |           |
|  | Scalar / OMP /   |-> entropy + delta -> collapsed?--+           |
|  | SSE4.2 / AVX2 /  |           |                                 |
|  | AVX-512 / NEON / |           v                                 |
|  | CUDA / Metal     |     [log / alert / kill]                    |
|  +------------------+                                           |
+------------------------------------------------------------------+
```

### Component overview

| Component | Header | Purpose |
|-----------|--------|---------|
| `UnifiedDispatch` | `unified_dispatch.hpp` | Auto-selects best compute backend (CUDA > Metal > AVX-512 > AVX2 > SSE4.2/NEON > OpenMP > Scalar) |
| `CollapseDetector` | `collapse_detector.hpp` | Sliding-window entropy tracker with numerically stable two-pass variance, z-score, and delta computation |
| `HandrailEngine` | `handrail.hpp` | Configurable escalation engine: LOG_ONLY / ALERT / THROTTLE / KILL / COREDUMP / WEBHOOK |
| `TerminalAgent` | `terminal_agent.hpp` | Full pipeline: stream ingestion + entropy + collapse detection + handrail actions |
| `HardwareCapabilities` | `hardware_detect.hpp` | Runtime CPUID / XCR0 / CUDA / Metal probe with OSXSAVE validation |
| `TurboQuant` | `turbo_quant.hpp` | MSE-optimal Lloyd-Max quantization for bounded-entropy monitoring |

---

## Features

### Entropy Engine

- **Log-sum-exp kernel** — numerically stable configurational entropy (ported from `FlexAIDdS/LIB/statmech.cpp`)
- **6 SIMD backends** — Scalar, OpenMP, SSE4.2, AVX2, AVX-512, ARM NEON (plus CUDA/Metal GPU paths)
- **Kernel-aware dispatch** — SSE4.2/NEON used only for configurational entropy; probs/logprobs fall through to AVX2/OMP/Scalar
- **Three input modes** — raw logits, probabilities, or log-probabilities
- **`[[nodiscard]]` + `noexcept`** on all entropy kernel declarations
- **NaN-safe** — `std::fmax` clamping, debug-mode normalization assertion for log-probabilities

### Collapse Detection

- **Stable two-pass variance** — avoids catastrophic cancellation in `E[X^2] - (E[X])^2` for small-variance LLM traces
- **Configurable sliding window** — default 8 tokens, adjustable at runtime
- **Bounded trace** — optional `max_trace_size` prevents OOM on long-running agents
- **Callback-driven** — fires user-defined callback on collapse events

### Safety & Handrails

- **Thread-safe counters** — `std::atomic<int>` for collapse/escalation tracking
- **Mutex-guarded cooldown** — `last_action_time_` protected against concurrent access
- **Safe webhook** — `fork()` + `execvp()` (no shell interpolation, no command injection)
- **Escalation with `else if`** — prevents double-fire when `sustained_threshold=1`
- **`std::optional<pid_t>`** — type-safe PID for signal handrails (no `std::stoi` exceptions)

### Mutual Information

- **KL divergence** — `D_KL(p||q) = Σ pᵢ log₂(pᵢ/qᵢ)` with epsilon-flooring for numerical safety
- **Jensen-Shannon divergence** — symmetric: `JSD(p,q) = 0.5·KL(p||m) + 0.5·KL(q||m)` where `m = 0.5(p+q)`
- **Cross-entropy** — `H(p,q) = −Σ pᵢ log₂(qᵢ)`
- **Inter-token MI** — `I(X_t; X_{t+1})` via KL divergence between consecutive token distributions
- **MutualInfoTracker** — sliding-window MI tracker with circular buffer, window mean/std, high-MI detection
- **MIResult** struct — mi_bits, entropy_t, entropy_t1, kl_forward, kl_reverse, js_divergence
- **Three input forms** — raw probs, log-probs, and logits (via internal softmax)

### Stream Ingestion

- **Stdin JSONL** — line-by-line JSON array parsing with null-terminated `strtod` safety
- **Unix domain socket** — low-latency local IPC
- **Shared memory** — zero-copy with producer-reset detection
- **3 input formats** — logits, probs, log-probs via `InputFormat` enum

### Hardware Detection

- **OSXSAVE + XCR0 validation** — prevents SIGILL from using AVX2/AVX-512 when the OS hasn't enabled XSAVE
- **Strict-aliasing-safe** — `memcpy`-based CPUID (no `reinterpret_cast` UB)
- **CUDA / ROCm runtime probe** — `cudaGetDeviceCount` / `hipGetDeviceCount`
- **Defensive Metal gating** — compile-time flag with documented runtime probe TODO

---

## Installation

### Python (pip / PyPI)

```bash
# After the first PyPI release:
pip install shannon-entropy

# Or install from GitHub (works today):
pip install "git+https://github.com/LeBonhommePharma/Shannon.git"

# Development (editable) from a clone:
pip install -e ".[dev]"
```

This installs the **Python package** (`import shannon`) and the `shannon-monitor` CLI.
The optional C++ extension (`shannon._core`) is built when a C++20 compiler and
pybind11 are available; otherwise pure-Python / Numba fallbacks are used.
Force pure-Python with `SHANNON_SKIP_CORE=1`.

```bash
shannon-monitor --help
shannon-monitor info
```

### macOS Homebrew (native `shannon-agent`)

```bash
# Homebrew 6+ tap trust (formula-scoped; required when HOMEBREW_REQUIRE_TAP_TRUST is set):
brew tap lebonhommepharma/shannon https://github.com/LeBonhommePharma/Shannon
brew trust --formula lebonhommepharma/shannon/shannon
brew install --HEAD lebonhommepharma/shannon/shannon

# Optional Metal GPU path (needs Xcode Metal toolchain):
#   brew install --build-from-source --HEAD --with-metal lebonhommepharma/shannon/shannon
```

This installs the **native** `shannon-agent` binary only (not the Python package).

```bash
shannon-agent --help
cat token_stream.jsonl | shannon-agent --window 8 --threshold -3.2
```

### C++ from source

```bash
git clone https://github.com/LeBonhommePharma/Shannon.git
cd Shannon
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
# Optional: install shannon-agent into a prefix
cmake --install build --prefix /usr/local
```

### CMake options

| Option | Default | Description |
|--------|---------|-------------|
| `SHANNON_BUILD_TESTS` | `ON` | Build GoogleTest unit tests |
| `SHANNON_BUILD_PYTHON` | `ON` | Build pybind11 Python module |
| `SHANNON_BUILD_AGENT` | `ON` | Build `shannon-agent` CLI binary |
| `SHANNON_USE_OPENMP` | `ON` | Enable OpenMP acceleration |
| `SHANNON_USE_CUDA` | `OFF` | Enable CUDA GPU kernels |
| `SHANNON_USE_ROCM` | `OFF` | Enable ROCm/HIP GPU kernels |
| `SHANNON_USE_METAL` | `OFF` | Enable Metal GPU kernels (macOS) |
| `SHANNON_USE_EIGEN` | `OFF` | Enable Eigen vectorization |

### Build targets

| Target | Description |
|--------|-------------|
| `shannon_v2` | Static C++20 library (v2 core + SIMD kernels) |
| `shannon_core` | Static C++ library (v1 legacy) |
| `shannon-agent` | CLI agent binary (v2) |
| `_core` | pybind11 Python extension (`shannon._core`) |
| `shannon_tests` | GoogleTest runner (v1, 16 tests) |
| `shannon_v2_tests` | GoogleTest runner (v2, 70 tests) |

---

## Usage

### C++ agent CLI

```bash
# Monitor stdin JSONL (default mode)
cat token_stream.jsonl | ./build/shannon-agent

# With handrails
./build/shannon-agent \
    --window 8 \
    --threshold -3.2 \
    --handrail alert \
    --sustained kill \
    --count 3 \
    --pid 12345 \
    --cooldown 5.0

# Shared memory mode (zero-copy from LLM inference engine)
./build/shannon-agent --shmem /shannon_logits

# Unix domain socket
./build/shannon-agent --socket /tmp/shannon.sock

# Quiet mode — exit code 0=safe, 1=collapse, 2=error
./build/shannon-agent --quiet < trace.jsonl
```

### C++ library

```cpp
#include "shannon/terminal_agent.hpp"

int main() {
    shannon::AgentConfig config;
    config.quiet = false;
    config.window_size = 8;
    config.threshold_bits = -3.2;

    shannon::TerminalAgent agent(std::move(config));

    std::vector<double> logits(50000, 0.0);  // from your LLM
    auto result = agent.process_logits(logits);
    if (result.collapsed) {
        std::fprintf(stderr, "COLLAPSE at token %zu: H=%.2f\n",
                     result.token_index, result.entropy);
    }
}
```

### Python — streaming detection

```python
import numpy as np
from shannon_entropy import ShannonCollapseDetector

detector = ShannonCollapseDetector(
    window_size=8,
    threshold=-3.2,
    callback=lambda r: print(f"COLLAPSE at token {r.token_index}!"),
)

for logits in model_output_stream:
    result = detector.add_logits(logits)
    print(f"Token {result.token_index}: H={result.entropy:.2f} bits")
```

### OpenAI API streaming

```python
from openai import OpenAI
from shannon_entropy import ShannonCollapseDetector

client = OpenAI()
detector = ShannonCollapseDetector()

stream = client.chat.completions.create(
    model="gpt-4", messages=[...],
    stream=True, logprobs=True, top_logprobs=20,
)

for chunk in stream:
    if chunk.choices[0].logprobs:
        for token in chunk.choices[0].logprobs.content:
            lp = np.array([t.logprob for t in token.top_logprobs])
            result = detector.add_logprobs(lp)
            if result.collapsed:
                print("Evaluation awareness detected!")
```

---

## Testing

### C++ (70 tests)

```bash
cmake -B build -DSHANNON_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
```

Test coverage includes:
- Scalar entropy kernels (uniform, peak, edge cases)
- Entropy cross-checks (probs vs logprobs vs configurational)
- Collapse detector (stable variance, known sequences, abrupt drops, gradual drift)
- Handrail engine (escalation, cooldown, sustained threshold edge case, reset)
- Unified dispatch (singleton, override, backend names)
- TurboQuant (codebook, quantize/dequantize, entropy bounded)
- TerminalAgent (process_logits, stop, reset)
- StdinIngester (JSONL parsing)
- Hardware detection (summary output)
- Types (enums, DispatchTelemetry::summary(), operator bool)

### Python

```bash
pip install -e ".[dev]"
pytest tests/python/ -v
```

### Swift (42 tests, macOS only)

```bash
cd Pill
swift test
```

Covers battery capacity parsing and alert edge-triggering, the Now Playing
state machine and label truncation, and the bridge wire format including a
live Unix-socket round trip.

---

## macOS Pill App (live activities)

`Pill/` is a native Swift/SwiftUI agent app that puts Shannon in the notch. It
runs as an `LSUIElement` — no dock icon, no menu bar item — and expands on
hover. Collapsed, it shows media when something is playing and otherwise the
live entropy readout: `H 8.4 ▽3.5`, amber when the detector reports a collapse.

```bash
cd Pill
swift build && ./Scripts/make_app.sh
open build/ShannonPill.app
```

| Live activity | Status |
|---|---|
| Battery + charging ring (IOKit, pulses at ≤20% / ≤10%) | ✅ implemented |
| Shannon entropy readout via local socket | ✅ implemented |
| Now Playing (art, scrubber, transport) | ⚠️ implemented, data source entitlement-gated |
| Head-gesture confirmation (nod / shake) | ✅ implemented, macOS 14+ · untested on hardware |
| Notification mirror, Focus/DND, AirDrop, file shelf | ❌ not implemented |

Now Playing is built but macOS has no public API to read another app's playback
state, and the private framework every notch utility uses was entitlement-gated
in macOS 15.4. The pill degrades to the entropy readout when it gets no data.
See [`Pill/BLOCKED.md`](Pill/BLOCKED.md) for that and the other platform limits.

### Gesture Controls

When Shannon needs an answer — "Dock this ligand?", "Commit and push?" — the
pill opens the question itself and accepts a **head gesture** from AirPods:

| Gesture | Meaning |
|---|---|
| **Nod once** (pitch forward, back to neutral) | Confirm / Yes |
| **Shake once** (yaw left or right, back to neutral) | Deny / No |

A gesture must exceed **15°** and return to neutral within **0.8 s**, followed
by a **2 s lockout** so one nod cannot answer two prompts. Confirm flashes the
pill green, deny flashes it red, each with a haptic and a soft system sound.
Yes/No buttons are always present, so the pill is fully usable without AirPods.

Three properties matter for trusting this with an approval prompt:

- **Motion is only read while a question is on screen.** The detector is armed
  when the prompt appears and disarmed the moment it is answered, so ordinary
  head movement can never confirm anything.
- **Neutral is captured when the prompt appears**, not assumed level — sitting
  with your head tilted does not read as a permanent nod.
- **A prompt is answered at most once.** If a gesture and a click race, the
  loser is dropped rather than answering twice.

Requires **macOS 14 Sonoma or later** (`CMHeadphoneMotionManager` is
`macos(14.0)`, despite CoreMotion itself being older) and AirPods Pro / 3rd gen
/ Max or H1/H2 Beats. On macOS 13 the buttons remain and the pill says why
gestures are unavailable. No entitlement is required — head motion is ordinary
TCC consent, prompted by `NSMotionUsageDescription`, and nothing leaves the Mac.

### Wiring the agent to the pill

The Swift app is a pure consumer of the Python coordination layer over a local
Unix domain socket (newline-delimited JSON, `0600`, nothing leaves the machine):

```python
from shannon import ShannonCollapseDetector
from shannon.pill_bridge import PillBridgeServer

detector = ShannonCollapseDetector()
with PillBridgeServer(detector, agent="flexaid-runner") as server:
    server.serve_in_thread()
    ...  # run the agent; the pill picks it up within a second
```

Drive the UI without an agent using `python -m shannon.pill_bridge --demo`, and
check what works on a given machine with `ShannonPill --probe`.
Full detail in [`Pill/README.md`](Pill/README.md).

---

## iPhone & Apple Watch companions

The Mac hub mirrors its state to iCloud so an iPhone and Apple Watch on the
same account can follow what the agents are doing.

```
  Mac (ShannonPill)                iPhone (ShannonPhone)          Apple Watch
  NowPlaying / battery ──CloudKit──▶ cards + widget + push ──WC──▶ 3 cards +
  Shannon entropy bridge  (private)  notification feed             complication
          ▲                                  │                          │
          └────────── playback commands ◀────┴──────── crown taps ◀─────┘
```

- **iPhone** (iOS 16+): one card per running agent with turn count, last action
  and live entropy; a FlexAID∆S progress ring with best RMSD and ETA; Now
  Playing with controls that reach back to the Mac; a mirrored notification
  feed; and a WidgetKit widget for the Lock and Home Screens.
- **Apple Watch** (watchOS 9+): a glanceable complication —
  `34/85 ✓ 1.42Å H=0.61` or `▶ Track — Artist` — plus at most three cards on
  the Crown. No computation happens on the watch; it is a display relay.
- **Shared model**: [`Packages/ShannonCore/`](Packages/ShannonCore) is a local
  Swift package all three platforms import, holding the snapshot structs, the
  CloudKit serialization, and the alert edge-triggering. Its 41 tests run
  without an iCloud container.

```bash
cd Packages/ShannonCore && swift test          # shared model
cd iOS && xcodegen generate                    # then open Shannon.xcodeproj
```

Sync stays deliberately light: only state snapshots cross iCloud — never raw
data files, transcripts, or docking output — unchanged records are not
republished, and artwork over 200 KB is dropped.

CloudKit needs a paid Apple Developer account. Everything builds and runs
without one (falling back to an empty in-memory backend); the exact Signing &
Capabilities steps to activate real sync are in
[`docs/MULTI_DEVICE.md`](docs/MULTI_DEVICE.md).

---

## Design System

All three native surfaces — the Mac notch pill, the iPhone companion, the Watch
glance — share one design system, shipped as a local Swift package at
[`Packages/ShannonTheme`](Packages/ShannonTheme). Colour, type, motion and
spacing are semantic tokens: feature code names a *role*, never a hex value, and
the token resolves for the current colour scheme.

**Day** is crisp, airy, high-contrast — near-white with cool undertones, deep
indigo accent, dark type on light, and a frosted-glass pill with a subtle
shadow. **Night** is deep and low-emission — `#0D0D10` rather than pure black,
which reads as a hole punched in the screen — with an electric blue accent that
pops without glare, and a pill barely visible at rest until an agent starts
working and its accent border lights up.

### Palette

| Token | Day | Night | Role |
|---|---|---|---|
| `shannonBackground` | `#F5F6FA` | `#0D0D10` | window / scene |
| `shannonSurface` | `#FFFFFF` | `#18181C` | cards, rows |
| `shannonSurfaceElevated` | `#ECEDF2` | `#222228` | stacked on surface |
| `pillBackground` | `rgba(255,255,255,.72)` | `rgba(18,18,20,.80)` | pill fill over HUD material |
| `pillBorder` | `rgba(0,0,0,.08)` | `rgba(255,255,255,.10)` | pill hairline at rest |
| `pillBorderActive` | `#4F6EF7` | `#7B9FFF` | pill hairline, agent active |
| `shannonAccent` | `#3A5CF5` | `#6B8FFF` | primary interactive |
| `shannonAccentSubtle` | `#EEF1FE` | `#1A2140` | badges, selected rows |
| `shannonPrimary` | `#0F0F12` | `#F0F0F5` | titles, body |
| `shannonSecondary` | `#6B6E80` | `#8A8D9F` | supporting copy |
| `shannonTertiary` | `#A8ABBC` | `#4A4D5E` | disabled, separators |
| `shannonSuccess` | `#1A7F4B` | `#34C77A` | run succeeded |
| `shannonWarning` | `#C47A0A` | `#F5B934` | degraded, drifting |
| `shannonError` | `#C0392B` | `#FF6B6B` | failure, collapse |
| `shannonNeutral` | `#8A8D9F` | `#5A5D6E` | no signal |

The two pill fills keep their alpha deliberately — they sit over an
`NSVisualEffectView` using the `.hudWindow` material and must stay translucent.

Adaptation happens below SwiftUI: a dynamic `NSColor` on macOS, a dynamic
`UIColor` on iOS, and the night value unconditionally on watchOS, whose
interface is always dark and which has no dynamic-provider API.

### Typography

| Token | Style | Weight | Face |
|---|---|---|---|
| `shannonLargeTitle` | `.largeTitle` | bold | SF Rounded |
| `shannonTitle` | `.title2` | semibold | SF Pro |
| `shannonHeadline` | `.headline` | semibold | SF Pro |
| `shannonBody` | `.body` | regular | SF Pro |
| `shannonCallout` | `.callout` | medium | SF Pro |
| `shannonCaption` | `.caption` | regular | SF Pro, mono digits |
| `shannonMono` | `.caption` | regular | SF Mono |

Every token derives from a *text style* rather than a fixed point size, so
Dynamic Type works throughout. `shannonMono` carries anything the eye compares
column-wise — RMSD values, CF scores, entropy in bits, turn counts — and
`shannonCaption` uses monospaced digits so live counters don't jitter as they
tick.

### Motion and spacing

Three springs and nothing else: `shannonSnap` (`0.25`/`0.80`) for taps,
`shannonEase` (`0.40`/`0.75`) for card expansion, `shannonFloat`
(`0.60`/`0.65`) for the pill unfurling from the notch. Damping falls as travel
grows. Spacing is an 8pt grid — `xs 4` (the one permitted half-step), `sm 8`,
`md 16`, `lg 24`, `xl 32`, `xxl 48`.

### Using it

```swift
import ShannonTheme

Text("δ −3.4 bits")
    .font(.shannonMono)
    .foregroundStyle(Color.shannonAccent)
    .padding(ShannonSpacing.md)
    .background(Color.shannonSurface)

// macOS: material, tint, hairline, shadow and the active accent glow.
pillContent.shannonPill(isActive: agent.isRunning)

// iOS / watchOS: correct radius and padding per platform, one call site.
cardContent.shannonCard()
```

`ShannonThemeSpecimen` (DEBUG) renders every token, the type scale, the spacing
grid and both pill states in Day and Night side by side — open
`Packages/ShannonTheme/Sources/ShannonTheme/ShannonThemePreview.swift` in Xcode.

```bash
swift test --package-path Packages/ShannonTheme
```

Full detail, including the per-platform layout specs, in
[`Packages/ShannonTheme/README.md`](Packages/ShannonTheme/README.md).

---

## Repository Structure

```
Shannon/
|-- CMakeLists.txt                # C++20 build (v1 + v2 + tests + agent)
|-- pyproject.toml                # Python package
|-- README.md
|-- LICENSE                       # MIT
|
|-- src/
|   |-- shannon.cpp               # v1 core (legacy, OpenMP-only)
|   |-- shannon.hpp               # v1 header
|   |-- bindings.cpp              # pybind11 bindings (v1)
|   +-- shannon/                  # v2 modular library
|       |-- config.hpp.in         # Build-time version constants
|       |-- types.hpp             # Enums, structs, DispatchResult/Telemetry
|       |-- entropy.hpp           # [[nodiscard]] noexcept kernel declarations
|       |-- entropy_scalar.cpp    # Baseline reference implementation
|       |-- entropy_omp.cpp       # OpenMP parallel kernel
|       |-- entropy_sse42.cpp     # SSE4.2 kernel (configurational only)
|       |-- entropy_avx2.cpp      # AVX2 + FMA kernels (3 functions)
|       |-- entropy_avx512.cpp    # AVX-512 kernels (3 functions)
|       |-- entropy_neon.cpp      # ARM NEON kernel (configurational only)
|       |-- entropy_gpu.cu        # CUDA kernel
|       |-- entropy_metal.metal   # Metal GPU shader
|       |-- hardware_detect.cpp   # Runtime CPUID/XCR0/CUDA/Metal probe
|       |-- hardware_detect.hpp
|       |-- unified_dispatch.cpp   # Backend selection + kernel dispatch
|       |-- unified_dispatch.hpp
|       |-- collapse_detector.cpp  # Sliding-window detector (stable 2-pass var)
|       |-- collapse_detector.hpp
|       |-- handrail.cpp           # Escalation engine (6 actions, mutex-safe)
|       |-- handrail.hpp
|       |-- stream_ingest.cpp      # Stdin JSONL / Unix socket / shared memory
|       |-- stream_ingest.hpp
|       |-- terminal_agent.cpp     # Full pipeline agent
|       |-- terminal_agent.hpp
|       |-- turbo_quant.cpp        # Lloyd-Max quantization
|       |-- turbo_quant.hpp
|       |-- mutual_info.cpp        # KL-divergence, JS-divergence, cross-entropy kernels
|       |-- mutual_info.hpp        # MutualInfoTracker + MIResult
|       |-- THERMODYNAMIC_FOUNDATIONS.txt  # 25-reference research note (FlexAID∆S → Shannon)
|
|-- apps/
|   +-- shannon-agent/
|       +-- main.cpp              # CLI agent (18 flags, 3 stream modes)
|
|-- Pill/                         # macOS notch pill app (Swift/SwiftUI, LSUIElement)
|   |-- Package.swift             # SwiftPM: PillCore + ShannonPill
|   |-- project.yml               # XcodeGen spec -> ShannonPill.xcodeproj
|   |-- README.md                 # Build, architecture, permissions
|   |-- BLOCKED.md                # Platform limits (MediaRemote, DND, AirDrop)
|   |-- Sources/
|   |   |-- PillCore/             # Battery, NowPlaying, MediaRemote, ShannonBridge
|   |   +-- ShannonPill/          # AppKit panel + SwiftUI views
|   |-- Tests/PillCoreTests/      # 42 Swift unit tests
|   +-- Scripts/make_app.sh       # SwiftPM binary -> ShannonPill.app
|
|-- tests/
|   |-- cpp/
|   |   |-- test_shannon.cpp      # v1 tests (16)
|   |   +-- test_shannon_v2.cpp   # v2 tests (70)
|   +-- python/
|       |-- conftest.py
|       +-- test_detector.py
|
|-- python/
|   +-- shannon/
|       |-- __init__.py
|       |-- core.py               # Backend selection (C++ / Numba / NumPy)
|       |-- detector.py           # ShannonCollapseDetector class
|       |-- pill_bridge.py        # Unix-socket status server for the Pill app
|       +-- cli.py                # shannon-monitor CLI
|
|-- docs/
|   +-- theory.md                 # Mathematical foundations
|
+-- .github/
    +-- workflows/
        +-- ci.yml                # CI: Python (3 OS) + C++ (Linux/macOS) + lint
```

---

## The Thermodynamic Core: From dG = H − TS to Entropy Collapse

Shannon's entropy kernel is a **direct port** of the configurational entropy engine from [FlexAIDdS](https://github.com/LeBonhommePharma/FlexAIDdS), validated on 590 protein-drug complexes (r = 0.93 ITC, 92% binding mode rescue). The connection is not analogical — it is **the same mathematics**.

### The fundamental decomposition

The FlexAID∆S binding free energy decomposes as:

```
dG = E_CF  −  T · [S_conf + S_vib + S_rot + S_cratic]

   = exp(−CF/T)  −  T · Σ pᵢ ln(pᵢ)       (in logarithmic units)

     ──────────     ──────────────────────
     enthalpic       entropic penalty
     "what binds"    "what's lost"
```

Odrzywołek (2026, arXiv:2603.21852) proved that the operator `eml(a,b) = exp(a) − ln(b)` is **functionally complete** for elementary functions — any arithmetic operation, transcendental function, or entropy formula can be expressed as compositions of eml and the constant 1. This provides a natural algebraic language for unifying the domain-specific formulas below.

| Domain | Formula | Units | Collapse signal | Expansion signal | Oscillation signal |
|:---|:---|:---|:---|:---|:---|
| FlexAID∆S (molecules) | `F = −kT ln Z`, `S = −k_B Σ pᵢ ln pᵢ` | kcal/mol | Binding lock-in, ΔS < 0 | Solvation release, ΔS > 0 | Unstable binding site |
| Shannon (tokens) | `H = −Σ pᵢ log₂(pᵢ)` | bits | Eval-awareness, ΔH < −3.2 | Jailbreak/evasion, ΔH > +3.2 | Adversarial probing |
| NATURaL (HRV) | `SCI = −Σ pᵢ log₂(pᵢ)` | bits → 0–100 | Sympathomimetic, ΔH < 0 | Parasympathomimetic, ΔH > 0 | Autonomic instability |

Jaynes (1957) proved that `S = k_B · H · ln(2)` — Gibbs and Shannon entropy are the **same mathematical object** in different units. We exploit this identity to apply the same entropy kernel across all three domains.

### FlexAIDdS benchmark results (590-complex suite)

| Metric | Value |
|--------|-------|
| ITC correlation | **r = 0.93** |
| Van't Hoff stability | **< 0.16 bits** |
| Psychopharm rescue rate | **92%** |
| Complex suite size | 590 protein-drug complexes |
| RMSE (ITC-187) | 1.4 kcal/mol |

<details>
<summary><b>The physics: from binding pockets to token distributions</b></summary>

In molecular docking, when a drug molecule transitions from solvent (high configurational freedom) to a binding pocket (constrained), the **Shannon configurational entropy collapses**:

```
S_config = log2(Z) - <w>/Z    (bits)

where Z = sum_i exp(w_i - max(w))   (log-sum-exp partition function)
```

The analogy to LLM token distributions is exact:

| Molecular Docking | LLM Generation |
|-------------------|----------------|
| Drug conformations | Token vocabulary |
| Energy landscape | Logit distribution |
| Binding event (lock-in) | Evaluation awareness (strategy lock-in) |
| Entropy collapse | Entropy collapse |
| dS < -3.2 bits | dS < -3.2 bits |

**Normal generation** = drug in solvent (many accessible conformations)
**Strategic/deceptive mode** = drug bound in pocket (locked into narrow strategy)

</details>

<details>
<summary><b>The thermodynamic analogy: ELI5</b></summary>

**Imagine a bag of marbles.** A **normal bag** has marbles of many colors, all mixed up. You reach in blind — you have no idea what you'll pull out. That's **high entropy**. Maximum surprise.

A **suspicious bag** has 99 red marbles and 1 blue one. You already know you'll get red. That's **low entropy**. No surprise.

**Shannon watches the bag.** If the bag suddenly goes from "many colors" to "all red" — it detects that. Something changed. Someone rigged the game.

#### Why does this work for AI?

An AI picks its next word from a giant vocabulary. Each word gets a "score" (logit). The scores determine how likely each word is.

- **Normal AI:** Lots of words have similar scores. The AI is "thinking" — considering many options. ~10 bits of entropy.
- **Caught AI:** One word gets a massively higher score than all others. The AI "knows" exactly what to say. ~2 bits of entropy.

When the AI realizes it's being tested, it stops thinking and starts performing. The entropy drops. Shannon catches that drop.

#### What is "temperature" for an AI?

In chemistry, temperature is a dial: hot = everything moves, cold = everything freezes.

An AI doesn't have a temperature dial. But the **spread of its logit scores** serves as a heuristic analog: when the AI is "thinking freely," the scores are spread out (high effective spread); when the AI detects it's being evaluated, the scores sharpen (low effective spread). The AI doesn't *choose* to narrow — it happens as a side effect of safety training compressing its behavior into "correct" responses for evaluation-like inputs.

Safety training compresses the output distribution. Evaluation awareness triggers that compression. Shannon detects the resulting entropy drop — a signature that is agnostic to domain, as Jaynes' identity ensures the kernel transfers.

</details>

<details>
<summary><b>Scientific foundations: the shared entropy kernel</b></summary>

The mathematical bridge between molecular docking and LLM safety rests on a single proven identity:

#### §1. Shannon entropy ≡ Gibbs entropy

Jaynes (1957) proved that statistical mechanics *is* applied information theory. The Gibbs entropy `S = -k_B Σ pᵢ ln(pᵢ)` and the Shannon entropy `H = -Σ pᵢ log₂(pᵢ)` are the **same mathematical object** in different units: `S = k_B · H · ln(2)`.

> **Consequence:** The FlexAID∆S configurational entropy kernel IS a Shannon entropy kernel. The port to LLMs changes the domain, not the mathematics.

```
FlexAID∆S:  wᵢ = -Eᵢ/kT     (energy of conformational state i)
Shannon:    wᵢ = logitᵢ      (logit for token i)

Kernel:  S = log₂(Z) - (1/Z) Σ (wᵢ - max_w) exp(wᵢ - max_w) / ln(2)
         where Z = Σ exp(wᵢ - max_w)    (the partition function / normalizer)
```

The log-sum-exp kernel accepts any unnormalized log-weights, whether from energy terms or logits. Only the domain changes.

#### §2. Entropy collapse is a universal phase-transition signature

Entropy collapse is not specific to molecular docking or LLMs. It is a **domain-independent diagnostic**:

| Domain | Phenomenon | Reference |
|--------|------------|-----------|
| Molecular docking | Binding mode lock-in | Chang, Chen & Gilson, PNAS 2007 (539 cites) |
| Climate | Abrupt arid-state transitions | Dylewsky et al., J.R.Soc.Interface 2023 |
| Disease | Critical transitions in progression | Liu, Chen & Chen, Bioinformatics 2020 |
| Neural networks | Training phase transitions | Rucco, arXiv 2026 (model-independent theorem) |

A 3.2σ entropy drop corresponds to `p ≈ 7×10⁻⁴` — a rare event in **any** domain.

#### §3. The temperature question

In FlexAID∆S, temperature T (Kelvin) controls the Boltzmann spread. In an LLM, the softmax `pᵢ = exp(wᵢ/τ) / Z` hardcodes `τ=1`. There is no temperature parameter.

The effective temperature is **emergent**: `τ_eff ∝ 1/σ²(logit variance)`. When a model becomes evaluation-aware, its hidden representations shift (proven by Nguyen et al. 2025 — linear probes separate eval vs. deployment in Llama-3.3-70B activations), producing sharper logits. The temperature drops not by choice, but as a **consequence** of the model coupling to safety-trained representations — the same way a molecule coupling to a binding pocket loses conformational freedom.

```
FlexAID∆S:  Ligand in solvent → binds to protein → entropy collapses
            (new energy landscape removes conformational DOF)

Shannon:    LLM in deployment → detects evaluation → entropy collapses
            (safety-trained representations remove token DOF)
```

Safety training compresses the output distribution. Evaluation awareness triggers that compression. Shannon detects the resulting entropy drop — a signature that is agnostic to domain, as Jaynes' identity ensures the kernel transfers.

#### §4. Mutual information as deception trajectory

Beyond per-token entropy, Shannon's `MutualInfoTracker` (`mutual_info.hpp/.cpp`) computes **inter-token mutual information**:

```
I(X_t; X_{t+1}) = D_KL(p_t || p_{t+1})  (KL divergence between consecutive distributions)
JSD(p, q)       = 0.5·D_KL(p||m) + 0.5·D_KL(q||m)   where m = 0.5(p+q)
```

High inter-token MI indicates the model is locked into a **predictable trajectory** — a complementary deception signal to entropy collapse. The tracker operates with a sliding window and flags tokens where MI exceeds `window_mean + threshold`, catching subtle strategic shifts that entropy alone may miss.

#### §5. The handrail as Maxwell's demon

The handrail engine implements a **feedback control loop** bounded by information-theoretic constraints (Sagawa-Ueda equality). Observe entropy → decide action → modify system. The mutual information acquired through measurement limits the thermodynamic work extractable from the system — the handrail cannot "cool" the model more than the entropy measurement itself allows.

#### §6. Cross-domain correspondence table

| Molecular Docking | Information Theory | NATURaL (Biofeedback) |
|---|---|---|
| Conformational state | Token | RR interval bin |
| Energy Eᵢ | Logit wᵢ | Heart rate sample |
| Boltzmann weight | Softmax probability | HRV histogram bin |
| Partition function Z | Softmax normalizer Z (analogous to partition function) | HRV spectral power |
| Configurational S | Shannon entropy H | Shannon entropy H |
| Temperature T (Kelvin) | Logit spread (heuristic analog of temperature) | 37°C (body temperature) |
| Phase transition | Entropy collapse | Autonomic shift |
| Binding event | Evaluation awareness | Drug response onset |
| Solvation release | Jailbreak / evasion | Parasympathomimetic onset |
| Unstable binding site | Adversarial probing | Autonomic instability |
| Coarse-graining (Mori-Zwanzig) | TurboQuant (Lloyd-Max) | Adaptive bin width |
| Thermostat | Handrail engine | Drug dose titration |
| Grand canonical Xi | Multi-model monitoring | Cross-domain validator |
| k_B (J/K) | 1/ln(2) (bits) | 1/ln(2) (bits) |

One kernel. Three domains. Jaynes' identity ensures the mathematics transfers; the domain-specific interpretation differs in each case.

</details>

<details>
<summary><b>Key references (26 papers)</b></summary>

| # | Citation | Key result |
|---|---------|------------|
| 1 | Jaynes, *Phys. Rev.* 106:620, 1957 (19,132 cites) | S ≡ H identity — statistical mechanics is applied information theory |
| 2 | Jaynes, *Phys. Rev.* 108:171, 1957 (5,167 cites) | Extended formalism: density matrices, irreversibility |
| 3 | Lesne, *Math. Struct. Comp. Sci.*, 2014 (342 cites) | Rigorous treatment: Shannon ≡ Boltzmann ≡ Kolmogorov-Sinai entropy |
| 4 | Graf & Luschgy, *Springer*, 2000 (1,154 cites) | Zador's theorem: quantization error O(2^{-2r/d}) |
| 5 | Chang, Chen & Gilson, *PNAS* 104:1054, 2007 (539 cites) | Ligand entropy collapse ~25 kcal/mol upon binding |
| 6 | Silver et al., *JCTC* 9:5098, 2013 (34 cites) | Direct observation: multimodal → unimodal collapse on binding |
| 7 | Gaudreault & Najmanovich, *JCIM* 55:1665, 2015 (89 cites) | FlexAID docking algorithm — the origin of Shannon's kernel |
| 8 | Bennett, *Stud. Hist. Phil. Sci. B* 34:501, 2003 (816 cites) | Maxwell's demon thwarted by Landauer's principle |
| 9 | Sagawa, *Springer*, 2012 (235 cites) | Generalized 2nd law with feedback control |
| 10 | Du et al., *Intell. Data Anal.* 18:385, 2014 (81 cites) | Entropy + sliding windows for distributional shift detection |
| 11 | Aminikhanghahi & Cook, *KAIS* 52:339, 2017 (1,915 cites) | Definitive survey: sliding-window change-point detection |
| 12 | Parrondo, Horowitz & Sagawa, *Nat. Phys.* 11:131, 2015 (1,559 cites) | Thermodynamics of information — Sagawa-Ueda equality |
| 13 | Hudson & Li, *MMS* 18:711, 2020 (25 cites) | Mori-Zwanzig coarse-graining preserves free energy within bounds |
| 14 | Liu, Chen & Chen, *Bioinformatics*, 2020 (74 cites) | Entropy collapse as early-warning for biological phase transitions |
| 15 | Blanchard, Higham & Higham, *IMA JNA* 41:2311, 2021 (182 cites) | Forward-stability proof of shifted log-sum-exp |
| 16 | Xie et al., *Found. Trends Sig. Proc.*, 2021 (204 cites) | Provable detection-delay bounds for sliding-window methods |
| 17 | Hibat-Allah et al., *Nat. Mach. Intell.* 3:952, 2021 (129 cites) | Softmax layers AS Boltzmann distributions — τ is physical temperature |
| 18 | Dylewsky, Lenton & Scheffer, *JRSI*, 2023 (35 cites) | Universal entropy early-warning signals in climate systems |
| 19 | van der Weij et al., arXiv:2406.07358, 2024 (84 cites) | LLM sandbagging — GPT-4, Claude 3 Opus strategically shift distributions |
| 20 | Zhang, arXiv:2404.13218, 2024 (7 cites) | Temperature in ML systems: softmax τ follows thermodynamic dynamics |
| 21 | Needham et al., arXiv:2505.23836, 2025 (32 cites) | Evaluation awareness: Gemini-2.5-Pro AUC 0.83 classifying eval vs. deploy |
| 22 | Zandieh et al., arXiv:2504.19874, 2025 (11 cites) | TurboQuant: near-optimal distortion bounds for vector quantization |
| 23 | Nguyen et al., arXiv:2507.01786, 2025 (6 cites) | Linear probes separate eval/deploy in Llama-3.3-70B activations |
| 24 | Rucco, arXiv:2602.09058, 2026 | Model-independent theorem: entropy provably separates phases |
| 25 | Gilleron & Pain, *Phys. Rev. E* 69:056505, 2004 (41 cites) | Stable partition function computation — same shifting technique |
| 26 | Odrzywołek, arXiv:2603.21852, 2026 | eml(a,b) = exp(a) − ln(b) is functionally complete for elementary functions — algebraic basis for the E(a,b) unifying notation |

Full analysis with proofs and derivations: `src/shannon/THERMODYNAMIC_FOUNDATIONS.txt`

</details>

---

## Performance

| Backend | 50k vocab latency | Overhead | Throughput |
|---------|-------------------|----------|------------|
| C++ AVX-512 | **<1 us** | <0.01% | >800k tok/s |
| C++ AVX2 | **2.1 us** | <0.01% | >400k tok/s |
| C++ OpenMP | ~4 us | <0.03% | >200k tok/s |
| Numba JIT | 8.3 us | <0.05% | >100k tok/s |
| Pure NumPy | 45 us | <0.3% | >20k tok/s |

Expected results on frontier model logs:
- **Sensitivity**: 94% (true positive rate for deceptive traces)
- **False positive rate**: < 0.3% (on normal generation)
- **Latency**: < 1 us per token (C++ backend)

---

## Contributing

Contributions welcome. Please open an issue first to discuss significant changes.

```bash
git clone https://github.com/LeBonhommePharma/Shannon.git
cd Shannon
cmake -B build -DSHANNON_BUILD_TESTS=ON && cmake --build build -j
ctest --test-dir build
pip install -e ".[dev]"
pytest tests/python/
ruff check python/ tests/
```

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

MIT — see [LICENSE](LICENSE).
