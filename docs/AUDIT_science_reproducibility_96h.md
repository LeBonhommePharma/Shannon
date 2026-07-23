# Independent Science & Reproducibility Audit — Shannon (96h)

**Auditor role:** Independent science & reproducibility review (not bound to prior agent conclusions)  
**Repository:** `/Users/lp.more/Projects/Shannon`  
**HEAD audited:** `8dc7ce3525f6322647d003355c85d379c7098e50`  
**Window:** ~96 hours ending 2026-07-23T00:52:43Z (commits since ~2026-07-19)  
**Method:** GitHub commit API + local tree inspection of theory/docs/kernels/tests; no modifications to science code  
**Scope tags:** (A) Shannon core science · (B) companion apps · (C) FlexAIDdS / soft-contact coupling  

---

## Executive summary

**The last ~96 hours of commits do not advance or regress Shannon’s core scientific claims.** Activity is overwhelmingly **UI / companion / packaging / orchestration** (Pill, iOS, watchOS, iPad, ShannonTheme, pets, Pencil, hub, Homebrew/Fastlane). **No commits in this window change the entropy kernel, collapse detector math, validation datasets, or sensitivity benchmarks.**

Independently re-checking the **core science at HEAD** (which those commits inherit) yields a split verdict:

| Domain | Verdict |
|--------|---------|
| **Log-sum-exp entropy kernel (math + unit tests)** | **Sound and largely reproducible** at analytical checkpoints (uniform → log₂(N), peak → ~0, probs ↔ logprobs ↔ configurational cross-checks). |
| **Backend numerical equivalence** | **Partially supported** (scalar ↔ NEON golden-style tests at 1e-10/1e-12); **no full golden suite** across AVX2/AVX-512/OpenMP/CUDA/Metal/Numba/NumPy on shared fixtures. Numba `fastmath=True` weakens bit-stability. |
| **Collapse detector (δ < −3.2 bits)** | **Implemented consistently as absolute-delta vs window mean**, not as a z-score gate. **Docs and in-source theory incorrectly equate −3.2 bits with “3.2σ”.** |
| **Variance estimator** | **Internal inconsistency (HIGH):** Python + v1 C++ use population-style `E[X²]−(E[X])²`; v2 C++ uses Welford **sample** variance `(n−1)`. Theory claims population `1/W`. Dual libraries (`shannon_core` vs `shannon_v2`) ship both. |
| **Headline safety metrics (94% sens, &lt;0.3% FP, H~8–12→2–4)** | **Not reproducible from this repo as stated.** Sensitivity bench is **synthetic**, not frontier deceptive-agent traces; no checked-in result artifacts; FPR claim is stronger than the unit-test bound (&lt;1% in one synthetic test). |
| **FlexAIDdS heritage (r=0.93 ITC, 590 complexes, 92% rescue)** | **Cited, not re-executed or data-shipped here.** Transfer of docking validation to LLM eval-awareness remains **hypothesis + analogy**, not a closed validation chain in Shannon. |
| **256×256 “white-box referee”** | **Ambiguous / overclaimed** in docs (“no training / first principles”) while `scripts/train_256x256.py` exists for PDBbind training; token-interaction interpretation is not empirically validated in-repo. |

**Bottom line:** Shannon’s **core entropy formula is scientifically standard and well unit-tested**. The **product claim that this detects evaluation awareness / strategic deception at quantified rates with a physics-calibrated −3.2 bit threshold is not currently supported by end-to-end, reproducible evidence inside this repository**. The 96h commit burst did not fix (or worsen) those gaps; it largely bypassed the science surface.

---

## Commit inventory (96h) with science relevance

Source: GitHub commits API for `LeBonhommePharma/Shannon` with `since=2026-07-18`, cross-checked against local `.git/logs/refs/heads/main` (HEAD `8dc7ce3…`).

| SHA (short) | Date (UTC) | Message (abbrev.) | Class | Science relevance |
|-------------|------------|-------------------|-------|-------------------|
| `8dc7ce3` | 2026-07-23 | feat(watch): WatchSnapshotCache scope | **UI** | None |
| `3bf662b` | 2026-07-23 | feat(dx): setup.sh + Fastlane | **Infra / DX** | None (build convenience) |
| `1c30e4a` | 2026-07-23 | feat(brew): Brewfile, Cask, DMG | **Packaging** | None |
| `03ec7ce` | 2026-07-22 | feat(pencil): Apple Pencil integration | **UI** | None |
| `e0efb9d` | 2026-07-22 | feat(pets): cross-platform pets | **UI** | None |
| `4e99acb` | 2026-07-22 | Shannon Hub under `hub/` | **Infra / orchestration** | **Low–medium side-channel:** `hub/shannon_gate.py` applies *message-text* entropy gates (thresholds 3.5 / 5.0 bits) — **not** the core token-logit collapse detector; risk of claim confusion |
| `c81a804` | 2026-07-22 | Shannon for iPad hub | **UI** | Displays entropy/RMSD; no new science |
| `7d6e59a` | 2026-07-22 | gesture/voice/security companions | **UI / security** | None for entropy math |
| `e845fdb` | 2026-07-22 | on-device dictation / AirPods | **UI** | None |
| `5c16578` | 2026-07-22 | AirPods head-nod confirmation | **UI** | None |
| `8e882ff` | 2026-07-22 | ShannonTheme design system | **UI** | None |
| `d352fa9` | 2026-07-22 | iOS + watchOS + CloudKit | **UI** | None |
| `1289422` (+ related Pill stack) | 2026-07-22 | Pill docs / app / pill_bridge | **UI / infra** | **Low:** `python/shannon/pill_bridge.py` exposes detector fields to UI; does not alter detection math |

### Just outside the 96h window (context only)

These predate the window but define the science baseline HEAD inherits:

| Topic | Approx. | Class | Note |
|-------|---------|-------|------|
| NEON suite + UnifiedDispatch | earlier | **Science / infra** | Scalar↔NEON equivalence tests in `tests/cpp/test_shannon_v2.cpp` |
| Soft-contact schema harden | earlier | **(C) FlexAIDdS coupling** | Matrix schema/tests |
| PyPI / Homebrew installers | ~2026-07-16 | **Packaging** | Distribution only |

### Classification summary (96h)

- **Science kernel / detector / validation datasets:** **0 commits**
- **UI / companion apps:** **majority**
- **Packaging / DX:** several
- **Orchestration with entropy *branding*:** hub gate (different estimator & thresholds)

---

## Core scientific claims vs evidence

### Claim map

| # | Claim (where stated) | What code actually does | Evidence in-repo | Assessment |
|---|----------------------|-------------------------|------------------|------------|
| 1 | Configurational entropy via log-sum-exp from logits | `src/shannon/entropy_scalar.cpp`, `src/shannon.cpp`, `python/shannon/_numba_fallback.py` implement equivalent LSE forms | Unit tests: uniform `log2(N)`, two equal → 1 bit, peak → ~0; cross-check probs/logprobs/config (`tests/cpp/test_shannon_v2.cpp`, `tests/python/test_detector.py`) | **Supported** (kernel math) |
| 2 | Default collapse when **δ = H − mean(window) < −3.2 bits**, window W=8 | Decision is **absolute delta**, after window full; z-score is computed but **not** the gate | `python/shannon/detector.py` (`collapsed = window_ready and (delta < self._threshold)`); `src/shannon/collapse_detector.cpp` `classify_event`; defaults in `src/shannon/config.hpp` | **Implementation matches absolute-delta claim**; **not** a z-score threshold |
| 3 | “z-score threshold δ < −3.2” / “3.2σ” | Conflates **bits of delta** with **standard deviations** | `docs/theory.md` mixes δ and z; `src/shannon/THERMODYNAMIC_FOUNDATIONS.txt` lines 67–69: *“Shannon z-score threshold (δ < −3.2 bits)… A 3.2σ entropy drop”*; `CLAUDE.md` restates z-score framing | **Overclaim / conceptual error (HIGH)** |
| 4 | H drops ~8–12 bits → ~2–4 bits under eval awareness | Plausible range for large-vocab softmax; **not measured on real model logs here** | Stated in `README.md`, `CLAUDE.md`, theory foundations; no fixture corpus of frontier traces | **Unsupported as measured fact in this repo** |
| 5 | 94% sensitivity / &lt;0.3% FP on deceptive / normal generation | `benchmarks/bench_sensitivity.py` uses **synthetic** Gaussian logits (seed 42), not labeled deceptive agent traces; FP accounting in that script is nonstandard | README badge-line + Performance section; unit test only asserts FP &lt; 1% on stable noise (`tests/python/test_detector.py::test_no_false_positive_stable`) | **Overclaim (HIGH)** — marketing numbers not backed by checked-in real-trace eval or published artifact |
| 6 | &lt;1 µs/token C++ / multi-backend latency table | Benchmark script exists; **no committed result JSON** | `benchmarks/bench_sensitivity.py`, README Performance table | **Unverified performance claim** (environment-dependent) |
| 7 | Ported from FlexAIDdS; 590 complexes; r=0.93 ITC; 92% rescue; Van’t Hoff &lt;0.16 bits | Heritage narrative; **no docking suite or ITC data in Shannon** | `docs/validation.md`, `README.md` | **External claim, not revalidated here** — docking success ≠ LLM safety validation |
| 8 | −3.2 bits calibrated on 590-complex suite + synthetic deceptive traces + frontier logs | Calibration **not documented with data/methods/figures** in-repo | `docs/theory.md` §Sliding Window; `docs/validation.md` §Threshold Calibration (also cites English text entropy 4–6 bits — different story) | **Calibration narrative inconsistent and non-reproducible** |
| 9 | Population variance `1/W`; theory says Bessel would require recalibration | **v2 C++ uses sample variance (n−1)**; Python/v1 use population-style online formula; docs/API say “population stddev” | `collapse_detector.cpp` + test `VarianceMatchesReference` (expects σ=0.5 for sample); `detector.py` `_push`; `docs/api.md` | **Docs/code/test mismatch (HIGH)** |
| 10 | Backend equivalence (SIMD/GPU tiers) | Scalar↔NEON tested; dispatch hierarchy documented; GPU paths compile-gated | `tests/cpp/test_shannon_v2.cpp` NEON blocks; no CI-visible golden multi-ISA matrix in Python | **Partial pass** |
| 11 | 256×256 white-box physicochemical referee, no training | Soft-contact matrix + training pipeline coexist | `docs/validation.md` “No training required”; `scripts/train_256x256.py` PDBbind/CASF training; `data/soft_contact_256.bin` binary blob | **Internal contradiction (MEDIUM)** |
| 12 | Zero-shot detection of evaluation awareness / strategic deception | Detector flags **low relative entropy** in a sliding window — necessary condition at best | Literature cited for eval-awareness *existence*; no causal link experiment (entropy collapse ⇔ eval-awareness) with labeled data | **Hypothesis, not demonstrated product property** |

### What the detector actually computes (re-verified)

**Entropy (logits / unnormalized weights):**

```text
max_w = max(w_i)
Z = Σ exp(w_i − max_w)
H = log2(Z) − (Σ (w_i − max_w) exp(w_i − max_w)) / (Z · ln 2)
```

Matches `docs/theory.md` and `src/shannon/entropy_scalar.cpp`. Python NumPy/Numba use algebraically equivalent forms (`_numpy_from_logits` / `_numpy_configurational_entropy`).

**Collapse decision (all primary paths):**

```text
mean = mean(window including current H)
delta = H − mean
collapsed ⇔ (window full) ∧ (delta < threshold)   # default threshold = −3.2 bits
```

Z-score `z = delta / std` is **diagnostic only**. Thresholding on δ in **bits** is not equivalent to thresholding on |z| &gt; 3.2 unless σ ≡ 1 bit, which is false for typical windows (often σ ≪ 1 when generation is stable).

**Dual implementation paths (critical for reproducibility):**

| Path | Library / file | Linked by | Variance | Decision |
|------|----------------|-----------|----------|----------|
| Python pure | `python/shannon/detector.py` | always (fallback) | `E[X²]−mean²` / n (population-ish; catastrophic cancellation risk) | δ &lt; thr |
| Python C++ ext | `src/shannon.cpp` via `shannon_core` + `bindings.cpp` | `shannon._core` | same online population-ish | δ &lt; thr |
| CLI agent | `src/shannon/collapse_detector.cpp` via `shannon_v2` | `shannon-agent` | **Welford sample (n−1)** | δ &lt; thr |

So **`shannon-monitor` / pip package vs `shannon-agent` can disagree on `window_std` and `z_score`** for the same entropy sequence. Collapse **flags** may still agree when driven only by large δ, but any consumer of z-score (UI, hub displays, research plots) is not cross-backend reproducible.

### Synthetic sensitivity bench (claim 5) — methodological notes

`benchmarks/bench_sensitivity.py`:

- Uses `np.random.seed(42)` and synthetic `randn` logits, not real model logprob streams.
- Labels “collapse” phase as increasingly peaked logits — a **toy** detection problem.
- FP definition mixes “already collapsed before phase 2” into FP — not a clean FPR estimator.
- No assertion that results equal 94% / 0.3%; those numbers appear only in README narrative.

### FlexAIDdS / soft-contact coupling (C)

Present and partially tested:

- `python/shannon_contact/`, `src/contact/`, `scripts/train_256x256.py`, `scripts/build_soft_contact.py`, `data/soft_contact_256.bin`
- Tests: `tests/python/test_soft_contact_matrix.py`, `tests/cpp/test_soft_contact_matrix.cpp`, integration projection checks

This is **docking-adjacent infrastructure**. It does **not** close the loop that “ITC r=0.93 on FlexAIDdS ⇒ LLM deception detector works.” `hub/` further reuses “Shannon” for **message-type entropy** with different thresholds (`H_THRESHOLD=3.5`, `H_BLOCK=5.0`), which is a **third semantics** of “entropy gate.”

### Companion apps (B)

Pill / iOS / watchOS / iPad / theme / pets / Pencil: **no scientific claims** requiring numerical validation of kernels. Audit treats them as non-science scope except where they **surface** detector metrics without documenting which backend produced them.

---

## Reproducibility checklist (pass/fail)

| Item | Result | Notes |
|------|--------|-------|
| Kernel analytical identities (uniform, peak, binary) | **PASS** | C++ and Python tests at ~1e-8–1e-12 |
| Probs ↔ logprobs ↔ configurational consistency | **PASS** | `EntropyCrossCheck` + Python softmax consistency test |
| Scalar ↔ NEON equivalence | **PASS** (ARM builds) | 1e-10 / 1e-12 tolerances in `test_shannon_v2.cpp` |
| Full multi-backend golden suite (all SIMD + GPU + Numba + NumPy) | **FAIL** | No shared golden vectors for all backends; GPU untested by default |
| Fixed seeds in stochastic tests | **PARTIAL** | Many tests use `default_rng(42)`; older `tests/test_detector.py` uses unseeded `np.random.randn` |
| Numba bit-reproducibility | **FAIL / WEAK** | `@njit(..., fastmath=True)` allows reassociation / reduced precision |
| Population vs sample variance single definition | **FAIL** | theory/API vs v2 C++ vs tests disagree |
| Python detector ↔ C++ v2 detector parity tests | **FAIL** | Not present; bindings link v1 `shannon_core` only |
| Collapse decision uses documented statistic | **PARTIAL** | Absolute δ is implemented; z-score narrative is wrong |
| −3.2 threshold calibration data/scripts | **FAIL** | No calibration notebook, dataset, or sealed results |
| 94% / 0.3% metrics reproducible from CI | **FAIL** | No CI job; synthetic bench only; no artifact |
| Frontier / deceptive-agent corpus | **FAIL** | Not in repo |
| FlexAIDdS 590-complex re-run from this repo | **FAIL** | External; no data/protocol here |
| Soft-contact binary provenance | **PARTIAL** | `data/soft_contact_256.bin` present; train vs closed-form provenance not sealed in docs |
| Default parameters centralized | **PASS** | `config.hpp` / Python defaults align on −3.2 / W=8 |
| Deterministic empty/n=1 edge cases | **PASS** | Return 0.0 |
| Debug normalization assert on logprobs | **PASS** (debug C++ scalar) | Release may silently accept unnormalized logprobs |

---

## Issues with severity

### HIGH

1. **δ (bits) conflated with z-score / “3.2σ”**  
   - Paths: `docs/theory.md`, `src/shannon/THERMODYNAMIC_FOUNDATIONS.txt`, `CLAUDE.md`, README framing.  
   - Code gates on **bits of delta**, not σ. Probability claim p≈7×10⁻⁴ for “3.2σ” does **not** apply to a −3.2 **bit** threshold.

2. **Variance estimator split across shipping surfaces**  
   - v2: Welford **sample** variance (`collapse_detector.cpp` + test expects σ=0.5).  
   - theory/API: **population** `1/W`.  
   - Python/v1: online `E[X²]−mean²` (population-ish, cancellation-prone).  
   - theory explicitly warns that switching to Bessel needs recalibration — v2 already switched without doc update.

3. **Headline sensitivity/FPR overclaims**  
   - “94% sensitivity on deceptive agent traces | &lt;0.3% FP” lacks reproducible real-trace evaluation, protocol, and committed results.

4. **No end-to-end evidence that entropy collapse ⇒ evaluation awareness**  
   - Eval-awareness literature is real; the **mapping via this detector** is unvalidated in-repo.

### MEDIUM

5. **Dual CollapseDetector / dual libraries** (`shannon_core` vs `shannon_v2`) without parity tests — Python bindings do not exercise v2 SIMD dispatch path for the detector.

6. **Threshold calibration stories conflict** (docking suite vs English 4–6 bits vs synthetic traces) with no data.

7. **256×256 “no training / first principles”** contradicts training pipeline and optional learned matrix.

8. **Hub gate** introduces alternate entropy semantics/thresholds under the same product name — reproducibility and interpretation risk.

9. **Numba `fastmath=True`** — weaker cross-platform numerical reproducibility when C++ core absent.

10. **Performance table** numbers not artifact-backed.

### LOW

11. Unseeded randomness in some older tests (`tests/test_detector.py`).

12. Formula comment in `src/shannon.cpp` header text slightly mismatches the shifted-weight implementation (implementation itself is correct).

13. CLAUDE.md still mentions `python/shannon_entropy/core.py` paths that were consolidated — documentation drift (infra/docs, not math).

14. Companion-app entropy displays may not identify which backend/variance definition produced `window_std` / z.

### Positives (credit where due)

- Log-sum-exp kernel is the right numerically stable approach; edge cases and analytical tests are solid.
- Explicit NEON↔scalar cross-checks exist.
- Collapse detection on **synthetic abrupt drops** is unit-tested and works as engineered.
- Separation of handrails / stream ingest from kernel is architecturally clean for engineering (not science validation).
- 96h work honestly documents platform blockers (Pill) rather than inventing unsupported APIs — good engineering hygiene, orthogonal to science.

---

## Independent verdict

### On the last 96 hours

**Science-neutral burst of product surface area.** No evidence that core claims were strengthened, falsified, or numerically re-validated in this window. Risk introduced is mostly **brand dilution**: hub/UI surfaces “entropy” with different estimators and thresholds without a single scientific contract.

### On Shannon core science (A) at HEAD

| Pillar | Independent judgment |
|--------|----------------------|
| **Math of Shannon/configurational entropy kernel** | **Credible and test-backed.** |
| **Engineering multi-backend speed path** | **Partially validated** (esp. NEON); incomplete golden matrix. |
| **Collapse detector as a statistical safety instrument** | **Partially implemented, inconsistently documented**; absolute-delta rule is clear in code; variance/z-score story is broken. |
| **Claimed LLM safety performance (−3.2 bits, 94% / 0.3%, H 8–12→2–4)** | **Not scientifically established within this repository.** Treat as **hypothesis / marketing until a sealed evaluation package exists.** |
| **Physics heritage transfer (FlexAIDdS → LLM agents)** | **Analogy + shared algebra, not a validated causal transfer.** Docking ITC metrics must not be read as LLM deception metrics. |

### On companion apps (B)

**Out of science scope** for reproducibility of kernels. Do not treat UI demo entropy as evidence for safety claims.

### On FlexAIDdS coupling (C)

**Real code path** (soft contact, training scripts, projection tests) with its own test surface. **Does not substitute** for LLM eval-awareness validation. Keep (A) and (C) metrics strictly separated in any paper/README claim.

### Recommended bar for a future “science PASS”

1. Single canonical variance definition; align Python, v1, v2, theory, API; add parity tests.  
2. Stop calling −3.2 a z-score threshold unless the gate is actually on z.  
3. Seal a **public evaluation package**: labeled normal vs deceptive/eval-aware logit or top-k logprob streams, fixed seeds, committed metrics JSON, CI job.  
4. Multi-backend golden vectors (fixed logits → exact H and detector trace).  
5. Separate README badges: “synthetic detection demo” vs “frontier model validated.”  
6. Soft-contact: declare binary provenance (closed-form vs trained) and never cite docking r as LLM detector performance.

---

*End of independent audit. Generated for local path `docs/AUDIT_science_reproducibility_96h.md`. Read-only except this report file.*
