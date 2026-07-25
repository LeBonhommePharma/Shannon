"""Missing logprobs must not become a one-hot H=0 collapse (P0.4)."""

from __future__ import annotations

import numpy as np

from shannon.integrations.logprob_feed import feed_token_logprobs, feed_top_logprobs
from shannon.detector import ShannonCollapseDetector


class _TLP:
    def __init__(self, logprob: float):
        self.logprob = logprob


def test_empty_top_logprobs_returns_none_no_collapse():
    d = ShannonCollapseDetector(window_size=8, threshold=-3.2)
    d.skipped_missing_logprobs = 0
    assert feed_token_logprobs(d, None) is None
    assert feed_token_logprobs(d, []) is None
    assert feed_top_logprobs(d, None) is None
    assert d.is_collapsed is False
    assert d.skipped_missing_logprobs >= 2


def test_real_top_logprobs_feeds_detector():
    d = ShannonCollapseDetector(window_size=8, threshold=-3.2)
    tops = [_TLP(np.log(0.25)) for _ in range(4)]
    res = feed_token_logprobs(d, tops)
    assert res is not None
    assert res.entropy > 0.5
    assert d.is_collapsed is False


def test_openai_stream_source_has_no_one_hot_fallback():
    """Structural: shipped streams must not call add_probs([1.0])."""
    from pathlib import Path

    root = Path(__file__).resolve().parents[2] / "python/shannon/integrations"
    for name in ("openai_stream.py", "xai_stream.py", "perplexity_stream.py"):
        text = (root / name).read_text()
        assert "add_probs(np.array([1.0]" not in text, name
