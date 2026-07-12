# Shannon Entropy Collapse Detection — Mathematical Foundations

## Table of Contents

1. [Configurational Entropy in Statistical Mechanics](#configurational-entropy-in-statistical-mechanics)
2. [Log-Sum-Exp Kernel](#log-sum-exp-kernel)
3. [Transfer to LLM Token Distributions](#transfer-to-llm-token-distributions)
4. [Sliding Window Detection](#sliding-window-detection)
5. [Z-Score Computation](#z-score-computation)
6. [Numerically Stable Variance](#numerically-stable-variance)
7. [Van't Hoff Consistency](#vant-hoff-consistency)
8. [The 256x256 Parameter Space](#the-256x256-parameter-space)
9. [SIMD Backend Dispatch](#simd-backend-dispatch)
10. [References](#references)

---

## Configurational Entropy in Statistical Mechanics

In molecular docking, the **configurational entropy** quantifies the number of
accessible microstates for a drug molecule in a protein binding site. When the
drug transitions from solvent (many conformations) to a binding pocket
(constrained), the entropy collapses:

```
ΔS_config = S_bound - S_free < 0
```

This is computed via the Shannon-Gibbs formulation:

```
S = -kB Σᵢ pᵢ ln(pᵢ)
```

where `pᵢ` is the Boltzmann probability of microstate `i`.

---

## Log-Sum-Exp Kernel

For numerical stability with unnormalized log-weights `wᵢ` (e.g., energy
scores in docking, or logits in LLMs), we use the log-sum-exp trick:

```
max_w = max(wᵢ)
Z = Σᵢ exp(wᵢ - max_w)                                    # partition function
S = log₂(Z) - (1/Z) Σᵢ (wᵢ - max_w) · exp(wᵢ - max_w) / ln(2)   # bits
```

This avoids overflow/underflow and preserves full double precision. The
formulation is mathematically equivalent to:

```
S = log₂(Z) - ⟨w⟩ / (Z · ln 2)
```

where `⟨w⟩` is the weighted sum of shifted log-weights.

### From probabilities

When the input is a probability distribution `{pᵢ}`:

```
H = -Σᵢ pᵢ log₂(pᵢ)     for pᵢ > ε
```

where `ε` is a small threshold (default `1e-15`) to avoid `0 · log(0)`.

### From log-probabilities

When the input is log-probabilities `{lpᵢ}` where `pᵢ = exp(lpᵢ)`:

```
H = -Σᵢ exp(lpᵢ) · lpᵢ · log₂(e)
```

**Precondition:** `{lpᵢ}` must be a normalized log-distribution, i.e.,
`Σᵢ exp(lpᵢ) = 1`. In debug builds (`NDEBUG` undefined), Shannon asserts this
with tolerance `|Z - 1| < 1e-4`.

---

## Transfer to LLM Token Distributions

The analogy is exact:

| Molecular Docking | LLM Generation |
|-------------------|----------------|
| Drug conformations | Token vocabulary |
| Energy landscape | Logit distribution |
| Binding event (lock-in) | Evaluation awareness (strategy lock-in) |
| Entropy collapse | Entropy collapse |
| ΔS < -3.2 bits | ΔS < -3.2 bits |

### Three input pathways

| Input | Function | Normalization |
|-------|----------|---------------|
| Raw logits | `configurational_entropy` | Log-sum-exp (handles unnormalized) |
| Probabilities | `entropy_from_probs` | Assumes `Σpᵢ = 1` |
| Log-probabilities | `entropy_from_logprobs` | Assumes `Σexp(lpᵢ) = 1` (asserted in debug) |

---

## Sliding Window Detection

We maintain a circular buffer of `W` recent entropy values (default `W = 8`)
and flag a collapse when:

```
δ = H_current - mean(H_window)
z = (H_current - mean) / stddev

collapsed = (δ < threshold) AND (window is full)
```

The default threshold of **-3.2 bits** was calibrated on:
1. The 590-complex molecular docking validation suite
2. Synthetic deceptive agent traces
3. Frontier model evaluation logs

The z-score provides a normalized measure of how many standard deviations
the current entropy is below the window mean. A z-score of -3.2 corresponds
to roughly the 0.07th percentile of a normal distribution.

---

## Z-Score Computation

The z-score is computed from the sliding window statistics:

```
z = (H_t - μ_window) / σ_window
```

where:

```
μ_window = (1/W) Σᵢ H_i            for i in window
σ_window = sqrt[(1/W) Σᵢ (H_i - μ)²]   (population stddev)
```

**Why population variance (not sample variance):** The sliding window IS the
population — it contains all recent entropy values, not a sample from a larger
distribution. Using `1/W` (not `1/(W-1)`) is correct. The default threshold
of -3.2 bits was calibrated against this population estimator, so switching
to Bessel correction would require recalibration.

---

## Numerically Stable Variance

### The problem

The naive variance formula `Var = E[X²] - (E[X])²` suffers from **catastrophic
cancellation** when the variance is small relative to the mean squared. For
typical LLM entropy values:

```
mean ≈ 8-12 bits
variance ≈ 0.01 bits²
E[X²] ≈ 64-144
(E[X])² ≈ 64-144
```

In double precision (15-16 significant figures), subtracting two nearly equal
numbers loses ~4 significant figures. At variance ≈ 1e-6, you lose ~8 figures.
This directly contaminates the z-score: `z = δ / σ`, and noise in `σ` produces
false positives or missed detections near the threshold.

### The fix: two-pass algorithm

Shannon v2 uses the numerically stable two-pass formula:

```
mean = (1/W) Σᵢ xᵢ
variance = (1/W) Σᵢ (xᵢ - mean)²
```

The subtraction `xᵢ - mean` is well-conditioned (both are ~8-12 bits, the
difference is ~0.01-0.1 bits). This preserves full precision.

For the small window sizes used here (default `W = 8`), two-pass is both
simpler and more numerically stable than Welford's online algorithm (which
is better suited for expanding or streaming accumulators, not fixed-size
circular buffers).

---

## Van't Hoff Consistency

In thermodynamics, the Van't Hoff equation relates entropy to the temperature
dependence of binding free energy:

```
ΔG = ΔH - TΔS
ln(K) = -ΔH/RT + ΔS/R
```

A Van't Hoff plot (ln K vs 1/T) should be linear if the entropy estimate is
thermodynamically consistent. The FlexAIDdS 590-complex suite achieved
**< 0.16 bits** deviation from Van't Hoff linearity, validating the
configurational entropy computation.

---

## The 256x256 Parameter Space

Shannon operates as a **white-box 256x256 physicochemical referee**:

- **256 entropy bins**: The entropy trace is discretised into 256 levels
  covering the range [0, 16] bits (sufficient for vocabularies up to 2^16)
- **256 temporal bins**: The sliding window and trace history use 256-step
  lookback for pattern matching

This creates a compact 65,536-parameter "fingerprint" of the model's
thermodynamic behaviour, enabling:

1. Real-time collapse detection (streaming)
2. Post-hoc trace analysis (batch)
3. Cross-model comparison (normalised fingerprints)

---

## SIMD Backend Dispatch

Shannon v2 uses a kernel-aware dispatch hierarchy:

```
1. User override (set_override)        → use specified backend if available + has kernel
2. CUDA / ROCm / Metal (GPU)           → only if compiled with SHANNON_USE_* + available
3. AVX-512                              → 8 doubles per vector op
4. AVX2 + FMA                           → 4 doubles per vector op
5. NEON/ASIMD (aarch64, full suite)     → 2 doubles + FMA; all three kernels
6. SSE4.2 (configurational only)        → 2 doubles
7. OpenMP                               → parallel; preferred over NEON for n ≥ 16k
8. Scalar                               → always available, reference implementation
```

SSE4.2 only implements `configurational_entropy`. NEON on aarch64 implements
the full suite (configurational + probs + logprobs) with vectorized max,
4-wide unrolled loads, and FMA accumulators; transcendental `exp`/`log2`
remain scalar (no NEON double-precision transcendental intrinsics). GPU
backends are never selected unless a kernel was actually compiled — avoiding
false Metal/CUDA preference that would fall through to scalar and skip NEON.

### Per-ISA compilation

Each SIMD kernel lives in its own translation unit compiled with targeted ISA
flags (`-mavx2`, `-mavx512f`, etc.). The rest of the library compiles at
baseline ISA. This prevents SIGILL on CPUs that don't support the higher
instruction sets — the dispatch only selects a backend if runtime hardware
detection confirms support.

### OSXSAVE / XCR0 validation

On x86, CPUID reports CPU capability but not OS enablement. Shannon checks
CPUID leaf 1 ECX bit 27 (`OSXSAVE`) and then reads `XCR0` via the `xgetbv`
instruction to confirm the OS has enabled YMM/ZMM state before selecting
AVX2 or AVX-512 backends. Without this check, the library would crash with
SIGILL in containers or VMs where XSAVE is not in use.

---

## References

1. Morency, L.-P. et al. FlexAIDdS: Configurational entropy in molecular
   docking. GitHub: lmorency/FlexAIDdS
2. Shannon, C. E. (1948). A Mathematical Theory of Communication.
   Bell System Technical Journal, 27(3), 379-423.
3. Gilson, M. K. et al. (1997). The statistical-thermodynamic basis for
   computation of binding affinities. Biophysical Journal, 72(3), 1047-1069.
4. Chan, T. F. et al. (1983). Algorithms for computing the sample variance:
   Analysis and recommendations. The American Statistician, 37(3), 242-247.
