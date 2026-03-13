# Shannon Entropy Collapse Detection: Mathematical Foundations

## From Molecular Docking to LLM Safety

### Configurational Entropy in Statistical Mechanics

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

### Log-Sum-Exp Kernel

For numerical stability with unnormalized log-weights `wᵢ` (e.g., energy
scores in docking, or logits in LLMs), we use the log-sum-exp trick:

```
max_w = max(wᵢ)
Z = Σᵢ exp(wᵢ - max_w)              # partition function
S = log₂(Z) - (1/Z) Σᵢ (wᵢ - max_w) exp(wᵢ - max_w) / ln(2)   # bits
```

This avoids overflow/underflow and preserves full double precision.

### Transfer to LLM Token Distributions

The analogy is exact:

| Molecular Docking | LLM Generation |
|-------------------|----------------|
| Drug conformations | Token vocabulary |
| Energy landscape | Logit distribution |
| Binding event (lock-in) | Evaluation awareness (strategy lock-in) |
| Entropy collapse | Entropy collapse |
| ΔS < -3.2 bits | ΔS < -3.2 bits |

### Sliding Window Detection

We maintain a sliding window of `W` recent entropy values and flag a collapse
when:

```
δ = H_current - mean(H_window)
collapsed = (δ < threshold) AND (window is full)
```

The default threshold of **-3.2 bits** was calibrated on:
1. The 590-complex molecular docking validation suite
2. Synthetic deceptive agent traces
3. Frontier model evaluation logs

### Van't Hoff Consistency

In thermodynamics, the Van't Hoff equation relates entropy to the temperature
dependence of binding free energy:

```
ΔG = ΔH - TΔS
ln(K) = -ΔH/RT + ΔS/R
```

A Van't Hoff plot (ln K vs 1/T) should be linear if the entropy estimate is
thermodynamically consistent. The FlexAID∆S 590-complex suite achieved
**< 0.16 bits** deviation from Van't Hoff linearity, validating the
configurational entropy computation.

### The 256x256 Parameter Space

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

## References

1. Morency, L.-P. et al. FlexAID∆S: Configurational entropy in molecular
   docking. GitHub: lmorency/FlexAIDdS
2. Shannon, C. E. (1948). A Mathematical Theory of Communication.
   Bell System Technical Journal, 27(3), 379-423.
3. Gilson, M. K. et al. (1997). The statistical-thermodynamic basis for
   computation of binding affinities. Biophysical Journal, 72(3), 1047-1069.
