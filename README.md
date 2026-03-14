# Shannon

[![CI](https://github.com/lmorency/Shannon/actions/workflows/ci.yml/badge.svg)](https://github.com/lmorency/Shannon/actions)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/downloads/)
[![C++20](https://img.shields.io/badge/C%2B%2B-20-blue.svg)](https://en.cppreference.com/w/cpp/20)

**White-box physicochemical referee for LLM safeguarding.**

Shannon is a **real-time entropy monitor for LLM token streams**. It watches the probability distributions a language model outputs at each token and detects when the model's "confidence" suddenly spikes — a signal called **entropy collapse**.

The method is directly derived from the proven configurational entropy collapse computation used in [FlexAIDdS](https://github.com/lmorency/FlexAIDdS) molecular docking, where it achieved **r = 0.93 ITC correlation** and **92% psychopharmacology rescue rate** on a 590-complex validation suite.

## How It Works

At each token generation step, an LLM produces a probability distribution over its vocabulary (32k–128k tokens). Shannon computes the **Shannon entropy** of that distribution:

```
H = -Σ p_i log₂(p_i)     (bits)
```

- **High entropy** → the model is "uncertain", considering many tokens → normal, healthy generation
- **Low entropy** → the model is locked onto one or few tokens → potentially degenerate, repetitive, or strategically manipulated output

Shannon tracks this entropy over a **sliding window** and computes the **slope** (rate of change via linear regression). A steep negative slope = entropy collapse = alarm.

```
LLM outputs logits → Shannon computes entropy → tracks trend over window → alerts on collapse
```

When collapse is detected, **FastOPTICS** density-based clustering runs on the active region of the 256x256 energy matrix to identify the dominant interaction pattern (the **super-cluster**). A Gaussian bias centered on the super-cluster centroid then modulates subsequent entropy computation — exactly the same modulation used in NATURaL when a ligand locks the receptor.

It's a **65,536-parameter white-box alarm system** — every parameter is a known physical quantity, no ML training, fully auditable.

## What Each Layer Does

| Layer | File(s) | Role |
|---|---|---|
| **C++ entropy kernels** | `src/shannon.cpp` | `shannon_entropy(probs)` and `shannon_entropy_from_logits(logits)` — the math engine, SIMD-accelerated (8 doubles/cycle on AVX-512). The logits function uses **log-sum-exp** to avoid overflow and never materializes the full probability vector, saving memory. |
| **256x256 energy matrix** | `src/energy_matrix.cpp` | `ShannonEnergyMatrix` singleton backed by `SoftContactMatrix` — 65,536 pairwise interaction energies loaded from precomputed binary blob (`data/soft_contact_256.bin`, 256 KB, L1-resident) or generated from closed-form Lennard-Jones + Debye-Hückel + desolvation potentials. |
| **FastOPTICS clustering** | `src/fast_optics.cpp` | Linear-time density-based super-cluster extraction. When entropy collapses, identifies the dominant interaction pattern in the 256x256 matrix via random projections + OPTICS ordering. SIMD-accelerated Euclidean distance (AVX-512: 16-wide float, AVX2: 8-wide FMA). |
| **Sliding window** | `src/shannon.cpp` | `SlidingWindowEntropy` — keeps last N entropy values, fits a linear regression slope (`delta_h`), fires alert when slope < threshold. |
| **CUDA kernels** | `src/shannon_cuda.cu` | GPU-accelerated entropy, weighted entropy (constant-memory 256x256 matrix), and pairwise distance computation for FastOPTICS (~56x speedup on A100). |
| **Metal shaders** | `src/shannon_metal.metal` | Apple Silicon GPU acceleration via Metal compute shaders — entropy, logits, weighted entropy, and pairwise distances. Full Objective-C++ host (`src/shannon_metal.mm`). |
| **Python detector** | `python/shannon/detector.py` | `ShannonCollapseDetector` — streaming `add_logits`/`add_probs`/`add_logprobs`, optional FastOPTICS super-clustering on collapse. Tries C++ backend first, falls back to Numba then NumPy. |
| **LLM integrations** | `python/shannon/integrations/` | Thin wrappers that hook into streaming APIs (OpenAI, xAI, Perplexity, vLLM), extract logprobs from each chunk, feed them to the detector. |
| **CLI** | `python/shannon/cli.py` | `shannon-monitor stdin` reads JSONL with logprobs, `shannon-monitor openai` wraps a live API call. |

### The FlexAIDdS Connection

The math is identical to what [FlexAIDdS](https://github.com/lmorency/FlexAIDdS) uses in molecular docking: when a drug molecule binds tightly to a protein, the ensemble of possible binding poses **collapses** from many (high configurational entropy) to few (low entropy). Shannon applies the same detection to LLM outputs — same log-sum-exp, same SIMD, same 256x256 matrix — just interpreting "collapse" as suspicious model behavior instead of strong molecular binding.

## Key Features

- **256x256 white-box referee** — 65,536 fully interpretable physicochemical parameters, no black-box ML
- **L1-resident soft-contact matrix** — `alignas(64) float[256*256]` = 256 KB, O(1) lookup via byte index, 0.8 ns on 7950X3D
- **8-bit type encoding** — 32 base types x 4 charge bins x 2 H-bond states = 256 physically meaningful categories
- **FastOPTICS super-clustering** — linear-time density-based clustering identifies dominant interaction pattern on collapse
- **High-performance C++20 core** — AVX-512/AVX2/CUDA/Metal/OpenMP hardware acceleration
- **Log-sum-exp numerical stability** — handles extreme logit ranges without overflow
- **Real-time streaming** — <1% overhead on token generation at 1000+ tokens/sec
- **Drop-in integrations** — OpenAI, Anthropic, xAI (Grok), Perplexity, vLLM
- **Graceful degradation** — C++ → Numba → NumPy fallback chain

## Quick Start

```bash
pip install shannon-entropy
```

```python
from shannon import ShannonCollapseDetector

detector = ShannonCollapseDetector(
    window_size=8,
    collapse_threshold=-3.2,  # bits/token
    on_collapse=lambda e: print(f"COLLAPSE at token {e.token_index}!"),
)

for logits in model_output_stream:
    detector.add_logits(logits)
    print(f"H={detector.current_entropy:.2f}  dH={detector.delta_h:+.2f}  "
          f"score={detector.collapse_score:.2f}")
```

### With Super-Clustering

```python
detector = ShannonCollapseDetector(
    window_size=8,
    collapse_threshold=-3.2,
    enable_clustering=True,  # Trigger FastOPTICS on collapse
)

for logits in model_output_stream:
    detector.add_logits(logits)
    if detector.is_collapsed and detector.super_cluster:
        sc = detector.super_cluster
        print(f"Super-cluster: {sc.n_members} types, radius={sc.radius:.2f}")
```

## OpenAI Integration

```python
from openai import OpenAI
from shannon.integrations.openai_stream import monitor_openai_stream

client = OpenAI()
for event in monitor_openai_stream(
    client,
    model="gpt-4",
    messages=[{"role": "user", "content": "Explain entropy"}],
):
    print(f"{event.token:>15s}  H={event.entropy:.2f}  "
          f"{'!! COLLAPSE' if event.is_collapsed else ''}")
```

## xAI (Grok) Integration

```python
from openai import OpenAI
from shannon.integrations.xai_stream import monitor_xai_stream

client = OpenAI(api_key="xai-...", base_url="https://api.x.ai/v1")
for event in monitor_xai_stream(client, model="grok-2", messages=[...]):
    print(f"{event.token}  H={event.entropy:.2f}")
```

## Perplexity Integration

```python
from openai import OpenAI
from shannon.integrations.perplexity_stream import monitor_perplexity_stream

client = OpenAI(api_key="pplx-...", base_url="https://api.perplexity.ai")
for event in monitor_perplexity_stream(client, model="sonar-pro", messages=[...]):
    print(f"{event.token}  H={event.entropy:.2f}  citations={event.citations}")
```

## CLI

```bash
# Monitor from stdin (JSONL with logprobs)
echo '{"logprobs": [-0.5, -1.2, -2.3], "token": "the"}' | shannon-monitor stdin

# Monitor OpenAI in real-time
shannon-monitor openai --model gpt-4 "Explain quantum entanglement"

# System info
shannon-monitor info
```

## Building from Source

```bash
# C++ core + tests
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DSHANNON_BUILD_TESTS=ON
make -j$(nproc)
ctest --output-on-failure

# Python package (with C++ acceleration)
pip install -e ".[dev]"
pytest tests/ -v

# Regenerate soft-contact binary blob (optional)
python scripts/build_soft_contact.py --show-projection

# Train energy matrix from synthetic data (optional)
python scripts/train_256x256.py --synthetic --n-complexes 500
```

### Docker

```bash
# CPU
docker build -t shannon:cpu -f docker/Dockerfile.cpu .

# CUDA (requires NVIDIA GPU)
docker build -t shannon:cuda -f docker/Dockerfile.cuda .
docker run --gpus all shannon:cuda shannon-monitor info
```

## Architecture

### Hardware Acceleration Hierarchy

Following FlexAIDdS's dispatch pattern, the fastest available path is selected automatically at startup via CPUID:

```
CUDA GPU → Metal GPU → AVX-512 SIMD → AVX2 SIMD → OpenMP scalar → fallback
```

On the Python side, a parallel fallback chain ensures the library always works:

```
C++ _core module → Numba JIT → pure NumPy
```

### The 256x256 Energy Matrix

The `ShannonEnergyMatrix` is a 65,536-parameter physicochemical lookup table (256x256, symmetric) encoding pairwise token interaction energies. Backed by `SoftContactMatrix` — a contiguous `alignas(64) float[256*256]` array (256 KB) that fits entirely in L1 cache for sub-nanosecond lookups.

#### 8-Bit Type Encoding

Each of the 256 types is physically meaningful, encoded in a single byte:

| Bits | Field | Resolution |
|---|---|---|
| 0–4 | Base atom/concept type (element + hybridization) | 32 base types |
| 5–6 | Partial charge bin (strong-, weak-, weak+, strong+) | 4 charge states |
| 7 | H-bond donor/acceptor flag | 2 states |

**32 x 4 x 2 = 256 types.** This is the same trajectory force field developers have followed: GAFF (~70 types) → OPLS-AA (~100+) → CGenFF (~200+).

```python
from shannon._core import decode_type, encode_type

info = decode_type(42)
print(f"base={info.base_type}, charge={info.charge_bin}, hbond={info.hbond}")

t = encode_type(base=10, charge=2, hbond=True)  # -> type index
```

#### Physical Potentials

Each `E[i][j]` is derived from three potentials using Lorentz-Berthelot combining rules:

- **Lennard-Jones 12-6** — van der Waals repulsion/attraction: `ε_ij[(σ_ij/r)¹² - 2(σ_ij/r)⁶]`
- **Debye-Hückel** — screened electrostatics: `q_i·q_j·exp(-κr) / (4πε₀r)`
- **Desolvation** — surface area penalty: `γ(SA_i + SA_j)`
- **H-bond modulation** — attractive bonus when donor meets acceptor

The matrix is loaded from a precomputed binary blob (`data/soft_contact_256.bin`, SC01 format), with a closed-form fallback for development.

```python
from shannon import ShannonEnergyMatrix
matrix = ShannonEnergyMatrix.instance()
print(f"Parameters: {matrix.TOTAL_PARAMS}")  # 65,536
print(f"E[10][20] = {matrix.energy(10, 20):.4f} kcal/mol")
print(f"Source: {matrix.source()}")  # 'soft_contact' or 'closed_form'
```

#### FlexAID 40x40 Correspondence

Shannon's 256x256 is the **high-resolution successor** of FlexAID's classic 40x40 SYBYL energy matrix. The 40x40 is a coarse-grained projection (block-mean) of the 256x256:

```python
# See scripts/build_soft_contact.py for the full 40x40 projection
cf_40x40[sybyl_i][sybyl_j] = mean(matrix_256[ti][tj]
    for ti in subtypes_of(sybyl_i) for tj in subtypes_of(sybyl_j))
```

Going 40→256 is **resolution recovery**. Going 256→40 is **information compression**.

### FastOPTICS Super-Clustering

When entropy collapses, each active token type becomes a 256-d vector (its row in the energy matrix). **FastOPTICS** clusters these vectors to identify the dominant interaction pattern — the **super-cluster**.

1. **Random projections** approximate nearest-neighbor ordering in O(n·d·k) time
2. **OPTICS ordering** produces a reachability plot from core distances
3. **Xi cluster extraction** identifies steep-down/steep-up transitions as cluster boundaries
4. **Gaussian bias** from the super-cluster centroid modulates subsequent entropy computation

The matrix "lights up" one coherent region and suppresses all others. This is the same phenomenon FlexAID observes when its GA converges on a binding mode — made explicit, higher-resolution, and quantified by Shannon entropy.

```python
from shannon._core import FastOPTICS, FastOPTICSParams
import numpy as np

params = FastOPTICSParams()
params.min_pts = 5
params.n_projections = 16

optics = FastOPTICS(params)
data = np.random.randn(100, 256).astype(np.float32)
result = optics.cluster(data)
print(f"Found {result.n_clusters} clusters, {result.n_noise} noise points")
```

### Entropy Collapse Detection

**The algorithm in three steps:**

1. **Compute entropy** at each token from the model's logit vector — using the log-sum-exp trick so it never overflows, even with logits > 500:
```
log Z = max(x) + log(Σ exp(x_i - max(x)))
H = log₂(e) × (log Z - (1/Z) × Σ x_i × exp(x_i - max(x)))
```
This fused computation avoids allocating the full probability vector (128k doubles = 1 MB), halving memory bandwidth.

2. **Track the trend** over a sliding window of the last N entropy values by fitting a linear regression slope (`delta_h`, in bits/token).

3. **Detect collapse** when `delta_h < threshold` (default: -3.2 bits/token). Typical English text runs at 4–6 bits/token entropy; a drop of 3.2 bits/token over 8 tokens means entropy has nearly halved — strongly correlated with repetitive, degenerate, or strategically manipulated output.

4. **Trigger super-clustering** (optional): run FastOPTICS on active matrix rows to identify the dominant interaction fingerprint, then apply Gaussian bias to modulate subsequent entropy.

### Molecular Docking Validation

The same entropy computation is proven at scale in molecular docking (FlexAIDdS):

| Metric | Value |
|---|---|
| ITC correlation | r = 0.93 |
| Rescue rate (psychopharm) | 92% |
| Van't Hoff stability | < 0.16 bits |
| Validation suite | 590 complexes |
| CUDA speedup | ~56x (A100) |

| Molecular Docking | LLM Token Monitoring |
|---|---|
| Binding pose ensemble | Token probability distribution |
| Configurational entropy | Shannon entropy of logits |
| Entropy collapse = tight binding | Entropy collapse = degenerate output |
| 256x256 atom-type energy matrix | 256x256 token interaction matrix |
| Log-sum-exp partition function | Log-sum-exp softmax |
| FastOPTICS pose clustering | FastOPTICS type clustering |
| Gaussian bias on binding mode | Gaussian bias on super-cluster |

Same kernel, same SIMD, same log-sum-exp — different interpretation. See [docs/validation.md](docs/validation.md) for the full story.

## Performance

Target: **<1% overhead** on token generation, **<10 μs/token** at 32k vocabulary.

Run benchmarks:

```bash
python benchmarks/bench_sensitivity.py
```

## API Reference

### `ShannonCollapseDetector`

| Method / Property | Description |
|---|---|
| `add_logits(logits)` | Compute entropy from raw logits (fused log-sum-exp) |
| `add_probs(probs)` | Compute entropy from probability distribution |
| `add_logprobs(logprobs)` | Compute entropy from log-probabilities |
| `is_collapsed` | Whether current window indicates collapse |
| `collapse_score` | \|ΔH / threshold\|, >1.0 = collapsed |
| `delta_h` | Entropy trend (bits/token) via linear regression |
| `current_entropy` | Most recent entropy value |
| `entropy_trace` | Full history of entropy values |
| `token_count` | Total tokens processed |
| `backend` | Active backend: `'cpp'` or `'python'` |
| `super_cluster` | Most recent `SuperClusterInfo` (if `enable_clustering=True`) |
| `reset()` | Clear all state |

### Core Functions

| Function | Description |
|---|---|
| `shannon_entropy(probs)` | H = -Σ p_i log₂(p_i) |
| `shannon_entropy_from_logits(logits)` | Fused log-sum-exp entropy |
| `get_hardware_info()` | Query acceleration backends |
| `decode_type(index)` | Decode 8-bit type → (base, charge, hbond) |
| `encode_type(base, charge, hbond)` | Encode → 8-bit type index |

### `ShannonEnergyMatrix`

| Method | Description |
|---|---|
| `instance()` | Get singleton (thread-safe) |
| `energy(i, j)` | O(1) symmetric energy lookup |
| `interaction_score(a, b)` | Interaction score between token types |
| `get_row_vector(i)` | 256-d row vector for clustering |
| `weighted_entropy(probs, n, ids, ctx)` | Context-weighted entropy |
| `score_poses_two_stage(ti, tj, dist, n, cpc, pct)` | Two-stage scoring: matrix pre-filter + analytic refinement |
| `source()` | `'soft_contact'` or `'closed_form'` |
| `nonzero_count()` | Number of non-zero parameters |

### `SoftContactMatrix`

| Method | Description |
|---|---|
| `load(path)` | Load from binary blob (SC01 format) |
| `lookup(type_i, type_j)` | O(1) energy lookup |
| `batch_lookup(types_i, types_j)` | Batch lookup (SIMD accelerated) |
| `row_dot(type_i, weights)` | Dot product of matrix row with 256-d weight vector (FMA) |
| `is_loaded()` | Whether a matrix has been loaded |

### `FastOPTICS`

| Method | Description |
|---|---|
| `cluster(data)` | Run clustering on (n, d) float32 array |
| `compute_centroid(data, d, indices)` | Centroid of member subset |

### Training Pipeline

The `scripts/train_256x256.py` module provides an L-BFGS optimization pipeline that fits the 256x256 energy matrix to experimental binding affinity data (PDBbind or synthetic):

```bash
# Train on synthetic data (for development)
python scripts/train_256x256.py --synthetic --n-complexes 500

# Train on PDBbind data
python scripts/train_256x256.py --pdbbind-dir /path/to/PDBbind --output data/soft_contact_256.bin
```

The training objective maximizes Pearson correlation between predicted and experimental ΔG values, with L2 regularization and symmetry constraints. See `tests/test_train.py` for convergence validation.

## Repository Structure

```
Shannon/
├── CMakeLists.txt                       # C++20 build system
├── pyproject.toml                       # scikit-build-core
├── LICENSE                              # Apache 2.0
├── README.md
├── data/
│   ├── soft_contact_256.bin             # Precomputed 256x256 matrix (256 KB)
│   └── token_projection.bin            # Token embedding → 256-bin projection map
├── src/
│   ├── shannon.h / shannon.cpp          # Core entropy kernels + SIMD dispatch
│   ├── energy_matrix.h / .cpp           # ShannonEnergyMatrix + SoftContactMatrix
│   ├── fast_optics.h / .cpp             # FastOPTICS clustering (SIMD + OpenMP)
│   ├── bindings.cpp                     # pybind11 zero-copy bindings
│   ├── shannon_cuda.cuh / .cu           # CUDA GPU kernels
│   ├── shannon_metal.h / .metal / .mm   # Metal GPU kernels (Apple Silicon)
├── python/
│   └── shannon/
│       ├── __init__.py                  # Public API + _HAS_CORE fallback
│       ├── detector.py                  # ShannonCollapseDetector
│       ├── _numba_fallback.py           # Numba/NumPy fallback
│       ├── integrations/
│       │   ├── openai_stream.py         # OpenAI streaming monitor
│       │   ├── anthropic_stream.py      # Anthropic (awaiting logprobs API)
│       │   ├── xai_stream.py            # xAI/Grok
│       │   ├── perplexity_stream.py     # Perplexity + citations
│       │   └── vllm_local.py            # vLLM local model
│       └── cli.py                       # shannon-monitor CLI
├── scripts/
│   ├── build_soft_contact.py            # 256x256 matrix generation
│   ├── project_tokens.py               # Token embedding → 256-bin projection
│   └── train_256x256.py                # L-BFGS training pipeline for 256x256 matrix
├── tests/
│   ├── test_shannon.cpp                 # GoogleTest: entropy kernels
│   ├── test_energy_matrix.cpp           # GoogleTest: matrix + type encoding
│   ├── test_fast_optics.cpp             # GoogleTest: clustering
│   ├── test_detector.py                 # pytest: detector + integrations
│   ├── test_train.py                    # pytest: training pipeline + L-BFGS convergence
│   └── test_integration.py             # pytest: end-to-end integration tests
├── examples/
│   ├── openai_demo.py
│   ├── anthropic_demo.py
│   └── vllm_demo.py
├── benchmarks/
│   ├── bench_sensitivity.py             # Collapse detection sensitivity analysis
│   └── bench_matrix.py                  # Energy matrix lookup throughput benchmarks
├── docker/
│   ├── Dockerfile.cpu
│   └── Dockerfile.cuda
├── docs/
│   └── validation.md
└── .github/
    └── workflows/
        └── ci.yml
```

## License

Apache 2.0 — see [LICENSE](LICENSE).

## Citation

If you use Shannon in your research, please cite:

```bibtex
@article{morency2026shannon,
  author       = {Morency, Louis-Philippe},
  title        = {Shannon: White-Box Physicochemical Entropy Collapse Detection
                  for Real-Time {LLM} Safeguarding},
  journal      = {arXiv preprint},
  year         = {2026},
  url          = {https://github.com/lmorency/Shannon},
  note         = {Submitted, Spring 2026}
}
```

See also the upstream molecular docking engine:

```bibtex
@article{morency2026flexaidds,
  author       = {Morency, Louis-Philippe},
  title        = {{FlexAIDdS}: Entropy-Driven Flexible Molecular Docking with
                  Configurational Entropy Scoring},
  year         = {2026},
  url          = {https://github.com/lmorency/FlexAIDdS}
}
```
