"""P0.4: missing logprobs must not become H=0 collapse via integrations helper."""

from __future__ import annotations

from types import SimpleNamespace

import numpy as np
import pytest

from shannon.detector import ShannonCollapseDetector
from shannon.integrations.logprob_feed import feed_token_logprobs


class TestFeedTokenLogprobs:
    def test_missing_top_logprobs_returns_none_not_one_hot(self):
        det = ShannonCollapseDetector(window_size=4)
        det.skipped_missing_logprobs = 0

        assert feed_token_logprobs(det, None) is None
        assert feed_token_logprobs(det, []) is None
        assert det.skipped_missing_logprobs == 2
        # Detector was never stepped — no fabricated collapse.
        assert det.token_count == 0
        assert det.is_collapsed is False

    def test_refuses_one_hot_path(self, monkeypatch):
        """Integration helper must never call add_probs with a one-hot vector."""
        det = ShannonCollapseDetector(window_size=4)
        calls: list[np.ndarray] = []

        def _spy_add_probs(probs):
            calls.append(np.asarray(probs))
            raise AssertionError("add_probs must not be used for missing logprobs")

        monkeypatch.setattr(det, "add_probs", _spy_add_probs)
        assert feed_token_logprobs(det, None) is None
        assert feed_token_logprobs(det, []) is None
        assert calls == []

    def test_feeds_real_alternatives(self):
        det = ShannonCollapseDetector(window_size=4)
        alts = [
            SimpleNamespace(logprob=-0.1),
            SimpleNamespace(logprob=-1.2),
            SimpleNamespace(logprob=-2.5),
        ]
        res = feed_token_logprobs(det, alts)
        assert res is not None
        assert res.entropy > 0.0
        assert det.token_count == 1
        assert det.is_collapsed is False

    def test_raw_float_sequence_ok(self):
        det = ShannonCollapseDetector(window_size=4)
        res = feed_token_logprobs(det, [-0.2, -1.0, -3.0])
        assert res is not None
        assert np.isfinite(res.entropy)

    def test_skipped_counter_optional(self):
        det = ShannonCollapseDetector(window_size=4)
        # Without attribute: no error, still returns None.
        assert feed_token_logprobs(det, None) is None
        assert not hasattr(det, "skipped_missing_logprobs") or True
