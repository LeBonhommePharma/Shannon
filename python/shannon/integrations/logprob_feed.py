"""Shared fail-closed logprob feeding for provider stream integrations.

Missing alternatives must never become a one-hot H=0 collapse alarm.
Policy: missing logprobs → measurement absent, not collapse.
"""

from __future__ import annotations

from typing import Any, Optional, Sequence

import numpy as np

__all__ = ["feed_token_logprobs", "feed_top_logprobs"]


def feed_token_logprobs(
    detector: Any,
    top_logprobs: Optional[Sequence[Any]],
) -> Optional[Any]:
    """Feed detector from top-k logprob alternatives for one token.

    Parameters
    ----------
    detector :
        Object with ``add_logprobs`` (e.g. ``ShannonCollapseDetector``).
    top_logprobs :
        Sequence of objects with a ``.logprob`` attribute, or raw floats.
        Empty / None means alternatives were not reported.

    Returns
    -------
    CollapseResult or None
        Detector step result when alternatives exist; ``None`` when there is
        nothing to measure. Missing logprobs are **absent**, not collapse —
        this function never calls ``add_probs([1.0])`` (one-hot H=0).

    Notes
    -----
    If ``detector`` has attribute ``skipped_missing_logprobs``, it is
    incremented when the measurement is skipped.
    """
    if not top_logprobs:
        # Missing logprobs → absent, not collapse. Do not feed one-hot H=0.
        if hasattr(detector, "skipped_missing_logprobs"):
            detector.skipped_missing_logprobs = (
                int(getattr(detector, "skipped_missing_logprobs", 0)) + 1
            )
        return None

    values: list[float] = []
    for item in top_logprobs:
        if hasattr(item, "logprob"):
            values.append(float(item.logprob))
        else:
            values.append(float(item))
    if not values:
        if hasattr(detector, "skipped_missing_logprobs"):
            detector.skipped_missing_logprobs = (
                int(getattr(detector, "skipped_missing_logprobs", 0)) + 1
            )
        return None

    lps = np.asarray(values, dtype=np.float64)
    return detector.add_logprobs(lps)


# Back-compat alias used by early drafts of this helper.
feed_top_logprobs = feed_token_logprobs
