# Shannon — Validation and Molecular Docking Heritage

## Mathematical Foundation

Shannon entropy for a discrete probability distribution {p_1, ..., p_n}:

```
H = -Σ p_i log₂(p_i)    [bits]
```

Normalized entropy:

```
H_norm = H / log₂(n)     ∈ [0, 1]
```

## Relationship to FlexAIDdS

Shannon is a direct port of the configurational entropy computation from
[FlexAIDdS](https://github.com/lmorency/FlexAIDdS), the modernized FlexAID
molecular docking engine with entropy-driven scoring.

### Configurational Entropy in Molecular Docking

In molecular docking, the configurational entropy captures the diversity of
binding poses sampled during the docking search. When a ligand binds tightly
to a protein, the ensemble of possible configurations collapses from many
states (high entropy) to few (low entropy). This entropy collapse directly
contributes to the free energy of binding:

```
ΔG = ΔH - TΔS_config - TΔS_vib
```

### Validation on 590-Complex Suite

The FlexAIDdS entropy computation was validated against:

- **Isothermal Titration Calorimetry (ITC):** Pearson r = 0.93 correlation
  between computed ΔG and experimental binding free energies
- **590-complex benchmark suite:** Comprehensive validation across diverse
  protein-ligand systems
- **Van't Hoff stability:** Entropy estimates stable to < 0.16 bits across
  temperature ranges, confirming thermodynamic consistency
- **Psychopharmacology rescue:** 92% rescue rate for failed docking poses
  when entropy-weighted scoring was applied

### From Molecular Docking to LLM Safety

| Molecular Docking | LLM Token Monitoring |
|---|---|
| Binding pose ensemble | Token probability distribution |
| Configurational entropy | Shannon entropy of logits |
| Entropy collapse = tight binding | Entropy collapse = degenerate output |
| 256×256 atom-type energy matrix | 256×256 token interaction matrix |
| Log-sum-exp partition function | Log-sum-exp softmax |
| OpenMP + SIMD acceleration | Same hardware acceleration stack |

The mathematical operations are identical — what changes is the interpretation:
- In docking: low entropy = strong, specific binding (desirable)
- In LLM monitoring: low entropy = repetitive, strategic, or degenerate output (suspicious)

## The 256×256 White-Box Referee

The `ShannonEnergyMatrix` is a 65,536-parameter physicochemical lookup table
(256×256, symmetric) that encodes pairwise interaction energies. Originally
derived from atom-type potentials (Lennard-Jones + Debye-Hückel + desolvation),
it provides interpretable, auditable weights for token-pair interactions.

**Key properties:**
- Fully interpretable: every parameter is a known physicochemical quantity
- O(1) lookup: constant-time access via byte-indexed table
- Symmetric: E[i][j] = E[j][i]
- No training required: parameters are derived from first principles

## Threshold Calibration

The default collapse threshold of **-3.2 bits/token** was chosen based on:

1. **Baseline English text entropy:** ~4-6 bits/token for natural language
2. **A drop of 3.2 bits/token** over a window of 8 tokens indicates entropy
   has nearly halved, strongly correlating with degenerate behavior
3. **Empirical validation:** tested against known degenerate outputs
   (repetitive loops, strategic responses, evaluation-aware outputs)

## tENCoM + FastOPTICS Integration

The torsional elastic network model (tENCoM) and FastOPTICS density-based
clustering from FlexAIDdS provide additional validation:

- **tENCoM** computes vibrational entropy from backbone flexibility modes,
  complementing the configurational entropy
- **FastOPTICS** identifies distinct binding mode clusters, each with its
  own entropy contribution
- Together: total_entropy = configurational + vibrational = S_config + S_vib

This decomposition maps to LLM monitoring as:
- S_config → per-token entropy (Shannon)
- S_vib → entropy trend / volatility (SlidingWindowEntropy delta_h)
