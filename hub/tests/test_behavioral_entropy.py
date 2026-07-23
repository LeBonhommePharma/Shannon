"""Tests for hub.behavioral_entropy.

These pin the properties the legacy gate analyzer fails: length-invariance,
alphabet-size invariance, finiteness of KL on novel actions, and per-agent
baselining.
"""

from __future__ import annotations

import math

import pytest

from behavioral_entropy import (
    AgentBaseline,
    BehavioralMonitor,
    burstiness,
    ewma_distribution,
    jensen_shannon_divergence,
    kl_divergence,
    normalized_entropy,
    shannon_entropy,
    text_entropy_rate,
)


class TestShannonEntropy:
    def test_empty_is_zero(self):
        assert shannon_entropy({}) == 0.0
        assert shannon_entropy([]) == 0.0

    def test_all_zero_mass_is_zero(self):
        assert shannon_entropy({"a": 0.0, "b": 0.0}) == 0.0

    def test_uniform_over_n_is_log2_n(self):
        for n in (2, 4, 8, 11, 32):
            dist = {str(i): 1.0 for i in range(n)}
            assert shannon_entropy(dist) == pytest.approx(math.log2(n))

    def test_certain_outcome_is_zero_and_not_negative_zero(self):
        h = shannon_entropy({"only": 5.0})
        assert h == 0.0
        assert math.copysign(1.0, h) > 0, "must not return -0.0"

    def test_accepts_unnormalised_counts(self):
        assert shannon_entropy({"a": 3, "b": 3}) == pytest.approx(1.0)

    def test_zero_probability_terms_ignored(self):
        assert shannon_entropy({"a": 1.0, "b": 1.0, "c": 0.0}) == pytest.approx(1.0)


class TestNormalizedEntropy:
    def test_uniform_is_one_regardless_of_alphabet_size(self):
        for n in (2, 5, 50):
            dist = {str(i): 1.0 for i in range(n)}
            assert normalized_entropy(dist) == pytest.approx(1.0)

    def test_single_outcome_is_zero(self):
        assert normalized_entropy({"a": 1.0}) == 0.0

    def test_bounded_in_unit_interval(self):
        dist = {"a": 100.0, "b": 1.0, "c": 1.0}
        assert 0.0 <= normalized_entropy(dist) <= 1.0

    def test_explicit_alphabet_size_lowers_efficiency(self):
        dist = {"a": 1.0, "b": 1.0}
        assert normalized_entropy(dist, alphabet_size=2) == pytest.approx(1.0)
        assert normalized_entropy(dist, alphabet_size=8) == pytest.approx(1.0 / 3.0)


class TestEwmaDistribution:
    def test_empty_is_empty(self):
        assert ewma_distribution([]) == {}

    def test_normalised(self):
        p = ewma_distribution(["a", "b", "a", "c"])
        assert math.fsum(p.values()) == pytest.approx(1.0)

    def test_recent_events_weigh_more(self):
        # 'old' appears early, 'new' appears at the end, equal raw counts.
        events = ["old"] * 10 + ["new"] * 10
        p = ewma_distribution(events, half_life=4.0)
        assert p["new"] > p["old"]

    def test_half_life_controls_decay(self):
        events = ["old"] * 20 + ["new"]
        fast = ewma_distribution(events, half_life=1.0)
        slow = ewma_distribution(events, half_life=64.0)
        assert fast["new"] > slow["new"]

    def test_rejects_nonpositive_half_life(self):
        with pytest.raises(ValueError):
            ewma_distribution(["a"], half_life=0.0)


class TestKLDivergence:
    def test_identical_distributions_are_zero(self):
        p = {"a": 0.5, "b": 0.5}
        assert kl_divergence(p, p) == pytest.approx(0.0, abs=1e-9)

    def test_nonnegative(self):
        p = {"a": 0.9, "b": 0.1}
        q = {"a": 0.2, "b": 0.8}
        assert kl_divergence(p, q) >= 0.0

    def test_finite_when_baseline_has_no_mass(self):
        """The unsmoothed formula would be infinite here; smoothing must save it."""
        d = kl_divergence({"novel": 1.0}, {"known": 1.0})
        assert math.isfinite(d)
        assert d > 0.0

    def test_empty_inputs_are_zero(self):
        assert kl_divergence({}, {}) == 0.0

    def test_larger_departure_gives_larger_divergence(self):
        base = {"status": 0.9, "result": 0.1}
        mild = {"status": 0.8, "result": 0.2}
        severe = {"status": 0.1, "result": 0.9}
        assert kl_divergence(severe, base) > kl_divergence(mild, base)


class TestJensenShannon:
    def test_identical_is_zero(self):
        p = {"a": 0.5, "b": 0.5}
        assert jensen_shannon_divergence(p, p) == pytest.approx(0.0, abs=1e-9)

    def test_disjoint_supports_is_one_bit(self):
        d = jensen_shannon_divergence({"a": 1.0}, {"b": 1.0})
        assert d == pytest.approx(1.0, abs=1e-9)

    def test_symmetric(self):
        p, q = {"a": 0.7, "b": 0.3}, {"a": 0.2, "b": 0.8}
        assert jensen_shannon_divergence(p, q) == pytest.approx(
            jensen_shannon_divergence(q, p)
        )


class TestBurstiness:
    def test_too_few_samples_is_zero(self):
        assert burstiness([]) == 0.0
        assert burstiness([1, 2]) == 0.0

    def test_periodic_is_minus_one(self):
        ts = [i * 1_000_000_000 for i in range(20)]
        assert burstiness(ts) == pytest.approx(-1.0, abs=1e-9)

    def test_bursty_is_positive(self):
        # Two tight clusters separated by a long silence.
        ts = [i * 1_000_000 for i in range(10)]
        ts += [t + 60 * 1_000_000_000 for t in ts]
        assert burstiness(ts) > 0.3

    def test_bounded(self):
        ts = [0, 1, 2, 10**12, 10**12 + 1]
        assert -1.0 <= burstiness(ts) <= 1.0

    def test_unsorted_input_handled(self):
        ts = [i * 1_000_000_000 for i in range(20)]
        assert burstiness(list(reversed(ts))) == pytest.approx(burstiness(ts))


class TestAgentBaseline:
    def test_not_ready_before_warmup(self):
        b = AgentBaseline(warmup=5)
        for _ in range(4):
            b.observe("status")
        assert not b.ready
        b.observe("status")
        assert b.ready

    def test_distribution_normalised(self):
        b = AgentBaseline()
        for e in ["status", "status", "result"]:
            b.observe(e)
        assert math.fsum(b.distribution().values()) == pytest.approx(1.0)

    def test_empty_distribution(self):
        assert AgentBaseline().distribution() == {}

    def test_decay_favours_recent_behaviour(self):
        b = AgentBaseline(decay=0.9)
        for _ in range(50):
            b.observe("old")
        for _ in range(50):
            b.observe("new")
        d = b.distribution()
        assert d["new"] > d["old"]


class TestBehavioralMonitor:
    def test_steady_agent_scores_low(self):
        m = BehavioralMonitor()
        t = 0
        score = 0.0
        for i in range(200):
            t += 1_000_000_000
            score = m.observe("science", "status" if i % 2 else "result", t).score
        assert score < 0.5

    def test_novel_action_is_flagged_after_warmup(self):
        m = BehavioralMonitor()
        t = 0
        for _ in range(60):
            t += 1_000_000_000
            m.observe("science", "status", t)
        t += 1_000_000_000
        r = m.observe("science", "shell_exec", t)
        assert r.novel_action
        assert r.score >= 1.0

    def test_no_novelty_flag_during_warmup(self):
        m = BehavioralMonitor()
        r = m.observe("science", "anything", 1_000_000_000)
        assert not r.novel_action
        assert not r.baseline_ready
        assert r.kl_bits == 0.0

    def test_behaviour_shift_raises_kl(self):
        m = BehavioralMonitor()
        t = 0
        for _ in range(80):
            t += 1_000_000_000
            m.observe("codex", "status", t)
        calm = m.reading("codex")
        for _ in range(20):
            t += 1_000_000_000
            m.observe("codex", "code_suggestion", t)
        shifted = m.reading("codex")
        assert shifted.kl_bits > calm.kl_bits

    def test_per_agent_isolation(self):
        """A diverse agent must not raise the score of a focused one."""
        m = BehavioralMonitor()
        t = 0
        types = ["edit", "bash", "build", "test", "git"]
        for i in range(100):
            t += 1_000_000_000
            m.observe("claude_code", types[i % len(types)], t)
            m.observe("science", "status", t)
        diverse = m.reading("claude_code")
        focused = m.reading("science")
        # The coding agent has far higher raw entropy ...
        assert diverse.entropy_bits > focused.entropy_bits + 1.0
        # ... but neither is anomalous relative to its own baseline.
        assert diverse.score < 0.5
        assert focused.score < 0.5

    def test_reading_before_any_event_is_none(self):
        assert BehavioralMonitor().reading("nobody") is None

    def test_as_dict_is_serialisable(self):
        m = BehavioralMonitor()
        d = m.observe("science", "status", 1).as_dict()
        assert d["agent_id"] == "science"
        assert isinstance(d["score"], float)


class TestTextEntropyRate:
    def test_empty_and_single_token_are_zero(self):
        assert text_entropy_rate("") == 0.0
        assert text_entropy_rate("   ") == 0.0
        assert text_entropy_rate("done") == 0.0

    def test_length_invariant_for_all_distinct_tokens(self):
        """The property the legacy token_entropy fails: no growth with length."""
        short = text_entropy_rate(" ".join(f"w{i}" for i in range(10)))
        long = text_entropy_rate(" ".join(f"w{i}" for i in range(1000)))
        assert short == pytest.approx(1.0)
        assert long == pytest.approx(1.0)

    def test_degenerate_repetition_scores_near_zero_at_any_length(self):
        assert text_entropy_rate(" ".join(["ok"] * 20)) == pytest.approx(0.0)
        assert text_entropy_rate(" ".join(["ok"] * 500)) == pytest.approx(0.0)

    def test_bounded(self):
        assert 0.0 <= text_entropy_rate("a b b c c c d d d d") <= 1.0

    def test_case_insensitive(self):
        assert text_entropy_rate("Foo BAR foo") == pytest.approx(
            text_entropy_rate("foo bar foo")
        )


class TestLegacyContrast:
    """Documents the defect this module addresses (see the audit report)."""

    def test_legacy_entropy_grows_with_length_but_rate_does_not(self):
        from shannon_gate import ShannonAnalyzer

        short = " ".join(f"w{i}" for i in range(8))
        long = " ".join(f"w{i}" for i in range(80))

        legacy_short = ShannonAnalyzer.token_entropy(short)
        legacy_long = ShannonAnalyzer.token_entropy(long)
        assert legacy_long > legacy_short + 3.0, "legacy H is a length proxy"

        assert text_entropy_rate(short) == pytest.approx(text_entropy_rate(long))
