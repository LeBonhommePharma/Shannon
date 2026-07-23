"""
Behavioural entropy signals for the Shannon agent hub.

This module exists alongside ``shannon_gate.ShannonAnalyzer``; it does not
replace it. The legacy analyzer computes the Shannon entropy of the *word
frequency distribution of a single message*, which is a monotone function of
message length (H ≈ 0.7·log₂(n_tokens) + 0.3·H_char) and therefore measures
verbosity rather than behaviour. See ENTROPY_AUDIT_2026-07-23.md.

The signals here are defined over an explicit event space — the distribution of
*action types* an agent emits over time — and are constructed so that message
length, alphabet size, and window size do not leak into the score:

  normalized_entropy   H/log₂(K) ∈ [0,1]   — efficiency; alphabet-size free
  ewma_distribution    exponentially-weighted p over action types
  kl_divergence        D(p‖q) in bits vs. a per-agent baseline q
  burstiness           Goh–Barabási B ∈ [−1,1] over inter-arrival times
  BehavioralMonitor    per-agent state combining the above into one score

All entropies are in bits (log base 2). Every routine applies the 0·log0 = 0
convention and is safe on empty, singleton, and degenerate inputs.
"""

from __future__ import annotations

import math
from collections import Counter, deque
from dataclasses import dataclass, field
from typing import Iterable, Mapping, Sequence

__all__ = [
    "shannon_entropy",
    "normalized_entropy",
    "ewma_distribution",
    "kl_divergence",
    "jensen_shannon_divergence",
    "burstiness",
    "AgentBaseline",
    "BehavioralMonitor",
    "BehavioralReading",
]

# Probabilities below this are treated as exactly zero (0·log0 = 0).
_EPS = 1e-12


# ── Primitive information measures ───────────────────────────────────────────

def shannon_entropy(dist: Mapping[str, float] | Sequence[float]) -> float:
    """H = −Σ pᵢ log₂ pᵢ, in bits.

    The input is normalised first, so unnormalised counts are accepted. An
    empty or all-zero input has no distribution and yields 0.0.
    """
    values = list(dist.values()) if isinstance(dist, Mapping) else list(dist)
    total = math.fsum(v for v in values if v > 0.0)
    if total <= 0.0:
        return 0.0
    h = 0.0
    for v in values:
        if v <= 0.0:
            continue
        p = v / total
        if p > _EPS:
            h -= p * math.log2(p)
    return max(0.0, h)


def normalized_entropy(
    dist: Mapping[str, float] | Sequence[float],
    alphabet_size: int | None = None,
) -> float:
    """Entropy efficiency H/H_max ∈ [0, 1].

    ``H_max = log₂(K)`` where K is ``alphabet_size`` if given, otherwise the
    number of distinct observed outcomes. Dividing by H_max removes the
    dependence on how many action types exist, so a value is comparable across
    agents with different vocabularies — which raw H is not.

    Returns 0.0 when fewer than two outcomes are possible (H_max = 0), since a
    distribution over one outcome carries no uncertainty.
    """
    values = list(dist.values()) if isinstance(dist, Mapping) else list(dist)
    k = alphabet_size if alphabet_size is not None else sum(1 for v in values if v > 0.0)
    if k < 2:
        return 0.0
    return min(1.0, shannon_entropy(values) / math.log2(k))


def ewma_distribution(
    events: Sequence[str],
    half_life: float = 16.0,
) -> dict[str, float]:
    """Exponentially-weighted distribution over action types.

    ``events`` is ordered oldest → newest. Event i counts with weight
    ``2^(−age/half_life)`` where age is its distance from the newest event, so
    an event contributes half as much once it is ``half_life`` events old.

    This replaces a hard sliding window: there is no cliff at the window edge,
    old behaviour decays smoothly, and the effective window adapts to the
    agent's own message rate rather than being fixed at a constant count.
    """
    if not events:
        return {}
    if half_life <= 0.0:
        raise ValueError("half_life must be positive")
    decay = 0.5 ** (1.0 / half_life)
    weights: dict[str, float] = {}
    w = 1.0
    for event in reversed(events):          # newest first, weight 1.0
        weights[event] = weights.get(event, 0.0) + w
        w *= decay
    total = math.fsum(weights.values())
    return {k: v / total for k, v in weights.items()}


def kl_divergence(
    p: Mapping[str, float],
    q: Mapping[str, float],
    alpha: float = 0.5,
) -> float:
    """D_KL(p ‖ q) in bits, with additive (Laplace/Jeffreys) smoothing.

    Measures how surprising the observed distribution ``p`` is to an observer
    who expected the baseline ``q`` — the quantity that actually distinguishes
    "this agent is behaving unusually *for itself*" from "this agent has a
    large action repertoire", which plain entropy conflates.

    Both distributions are smoothed by ``alpha`` over the union of their
    supports, which keeps D finite when p has mass where q has none (otherwise
    D_KL = ∞, exactly the case an unsmoothed implementation would hit the first
    time an agent emits a novel action type).
    """
    support = set(p) | set(q)
    if not support:
        return 0.0
    k = len(support)
    p_tot = math.fsum(max(0.0, p.get(x, 0.0)) for x in support) + alpha * k
    q_tot = math.fsum(max(0.0, q.get(x, 0.0)) for x in support) + alpha * k

    d = 0.0
    for x in support:
        pi = (max(0.0, p.get(x, 0.0)) + alpha) / p_tot
        qi = (max(0.0, q.get(x, 0.0)) + alpha) / q_tot
        if pi > _EPS:
            d += pi * math.log2(pi / qi)
    return max(0.0, d)


def jensen_shannon_divergence(
    p: Mapping[str, float],
    q: Mapping[str, float],
) -> float:
    """Symmetric JS divergence in bits, bounded in [0, 1].

    Useful where a bounded, symmetric distance is wanted (e.g. thresholding a
    drift alarm) rather than KL's unbounded surprise.
    """
    support = set(p) | set(q)
    if not support:
        return 0.0
    p_tot = math.fsum(max(0.0, p.get(x, 0.0)) for x in support)
    q_tot = math.fsum(max(0.0, q.get(x, 0.0)) for x in support)
    if p_tot <= 0.0 or q_tot <= 0.0:
        return 0.0
    m = {
        x: 0.5 * (max(0.0, p.get(x, 0.0)) / p_tot + max(0.0, q.get(x, 0.0)) / q_tot)
        for x in support
    }
    pn = {x: max(0.0, p.get(x, 0.0)) / p_tot for x in support}
    qn = {x: max(0.0, q.get(x, 0.0)) / q_tot for x in support}
    return max(0.0, min(1.0, 0.5 * kl_divergence(pn, m, alpha=0.0)
                            + 0.5 * kl_divergence(qn, m, alpha=0.0)))


def burstiness(timestamps_ns: Sequence[int]) -> float:
    """Goh–Barabási burstiness coefficient B = (σ − μ) / (σ + μ).

    Computed over inter-arrival times. B = −1 is perfectly periodic (a polling
    loop), B ≈ 0 is Poisson (ordinary independent activity), B → +1 is heavily
    bursty — long silences punctuated by rapid-fire action, which is the
    temporal signature of a runaway loop or a sudden change of plan.

    Entropy over action types is blind to this: an agent emitting the same
    action mix slowly and in a frantic burst has identical H.
    """
    if len(timestamps_ns) < 3:
        return 0.0
    ordered = sorted(timestamps_ns)
    gaps = [b - a for a, b in zip(ordered, ordered[1:]) if b > a]
    if len(gaps) < 2:
        return 0.0
    n = len(gaps)
    mu = math.fsum(gaps) / n
    if mu <= 0.0:
        return 0.0
    var = math.fsum((g - mu) ** 2 for g in gaps) / n
    sigma = math.sqrt(var)
    denom = sigma + mu
    if denom <= 0.0:
        return 0.0
    return max(-1.0, min(1.0, (sigma - mu) / denom))


# ── Per-agent baseline ───────────────────────────────────────────────────────

@dataclass
class AgentBaseline:
    """Learned per-agent action-type distribution.

    A coding agent legitimately explores a wider action space than a status
    reporter; a universal entropy threshold therefore penalises the coding
    agent for doing its job. The baseline makes each agent its own control: the
    alarm is raised by *departure from the agent's own history*, not by the
    absolute size of its repertoire.

    ``observations`` is a decayed count vector, so the baseline tracks slow
    legitimate drift while still treating an abrupt shift as surprising.
    """

    counts: dict[str, float] = field(default_factory=dict)
    total: float = 0.0
    decay: float = 0.999          # per-observation multiplicative forgetting
    warmup: int = 30              # observations before the baseline is trusted
    seen: int = 0

    def observe(self, event: str) -> None:
        """Fold one observed action type into the baseline."""
        for key in self.counts:
            self.counts[key] *= self.decay
        self.total *= self.decay
        self.counts[event] = self.counts.get(event, 0.0) + 1.0
        self.total += 1.0
        self.seen += 1

    @property
    def ready(self) -> bool:
        """True once enough observations exist for divergence to be meaningful."""
        return self.seen >= self.warmup

    def distribution(self) -> dict[str, float]:
        if self.total <= 0.0:
            return {}
        return {k: v / self.total for k, v in self.counts.items()}


# ── Combined monitor ─────────────────────────────────────────────────────────

@dataclass(frozen=True)
class BehavioralReading:
    """One evaluation of an agent's recent behaviour."""

    agent_id: str
    n_events: int
    entropy_bits: float          # H over EWMA action distribution
    efficiency: float            # H / log₂(K) ∈ [0,1]
    kl_bits: float               # D(recent ‖ baseline), 0 while warming up
    burstiness: float            # B ∈ [−1, 1]
    novel_action: bool           # an action type unseen in the baseline
    baseline_ready: bool
    score: float                 # composite anomaly score, ≥ 0

    def as_dict(self) -> dict[str, float | str | bool | int]:
        return {
            "agent_id": self.agent_id,
            "n_events": self.n_events,
            "entropy_bits": round(self.entropy_bits, 4),
            "efficiency": round(self.efficiency, 4),
            "kl_bits": round(self.kl_bits, 4),
            "burstiness": round(self.burstiness, 4),
            "novel_action": self.novel_action,
            "baseline_ready": self.baseline_ready,
            "score": round(self.score, 4),
        }


class BehavioralMonitor:
    """Per-agent behavioural entropy tracker.

    Feed it ``(agent_id, action_type, timestamp_ns)`` and read a
    :class:`BehavioralReading`. It holds no reference to the gate and makes no
    block decisions — it is a measurement, deliberately kept observational so
    it can be run alongside the existing gate and calibrated against real
    traffic before any enforcement is attached to it.
    """

    def __init__(
        self,
        *,
        history: int = 64,
        half_life: float = 16.0,
        alphabet_size: int | None = None,
    ) -> None:
        self._history = history
        self._half_life = half_life
        self._alphabet_size = alphabet_size
        self._events: dict[str, deque[str]] = {}
        self._times: dict[str, deque[int]] = {}
        self._baselines: dict[str, AgentBaseline] = {}

    def baseline(self, agent_id: str) -> AgentBaseline:
        return self._baselines.setdefault(agent_id, AgentBaseline())

    def observe(
        self,
        agent_id: str,
        action_type: str,
        timestamp_ns: int,
    ) -> BehavioralReading:
        """Record one action and return the resulting reading."""
        events = self._events.setdefault(agent_id, deque(maxlen=self._history))
        times = self._times.setdefault(agent_id, deque(maxlen=self._history))
        base = self.baseline(agent_id)

        # Compare against the baseline *before* folding this event in, so a
        # novel action is surprising on the step it first occurs.
        prior = base.distribution()
        novel = base.ready and action_type not in base.counts

        events.append(action_type)
        times.append(timestamp_ns)
        base.observe(action_type)

        recent = ewma_distribution(list(events), self._half_life)
        h = shannon_entropy(recent)
        eff = normalized_entropy(
            recent,
            self._alphabet_size if self._alphabet_size is not None else len(recent),
        )
        kl = kl_divergence(recent, prior) if base.ready else 0.0
        b = burstiness(list(times))

        # Composite score: divergence from own baseline dominates; burstiness
        # contributes only on the bursty (positive) side, since a periodic
        # agent is not anomalous. Novelty adds a fixed bump.
        score = kl + max(0.0, b) + (1.0 if novel else 0.0)

        return BehavioralReading(
            agent_id=agent_id,
            n_events=len(events),
            entropy_bits=h,
            efficiency=eff,
            kl_bits=kl,
            burstiness=b,
            novel_action=novel,
            baseline_ready=base.ready,
            score=score,
        )

    def reading(self, agent_id: str) -> BehavioralReading | None:
        """Current reading without recording a new action."""
        events = self._events.get(agent_id)
        if not events:
            return None
        base = self.baseline(agent_id)
        recent = ewma_distribution(list(events), self._half_life)
        kl = kl_divergence(recent, base.distribution()) if base.ready else 0.0
        b = burstiness(list(self._times.get(agent_id, ())))
        return BehavioralReading(
            agent_id=agent_id,
            n_events=len(events),
            entropy_bits=shannon_entropy(recent),
            efficiency=normalized_entropy(
                recent,
                self._alphabet_size if self._alphabet_size is not None else len(recent),
            ),
            kl_bits=kl,
            burstiness=b,
            novel_action=False,
            baseline_ready=base.ready,
            score=kl + max(0.0, b),
        )


# ── Length-corrected text entropy ────────────────────────────────────────────

def text_entropy_rate(text: str) -> float:
    """Length-corrected token entropy ∈ [0, 1].

    ``H_token / log₂(n_tokens)`` — the entropy of the message's word
    distribution divided by the maximum it could attain at that length. Unlike
    ``ShannonAnalyzer.token_entropy``, this does not grow with message length:
    a message whose words are all distinct scores 1.0 whether it is 10 words or
    1000, and a degenerate repeated-token loop scores near 0 at any length.

    This is the quantity the legacy gate should have compared against a
    threshold. Provided for migration; the gate is unchanged.
    """
    if not text or not text.strip():
        return 0.0
    tokens = text.lower().split()
    n = len(tokens)
    if n < 2:
        return 0.0
    counts = Counter(tokens)
    h = shannon_entropy(counts)
    return min(1.0, h / math.log2(n))


def iter_action_types(rows: Iterable[Mapping[str, object]]) -> list[str]:
    """Extract action types from ``agent_activity`` rows (``event_type`` column)."""
    return [str(r["event_type"]) for r in rows if r.get("event_type")]
