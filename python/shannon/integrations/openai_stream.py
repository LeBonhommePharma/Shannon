# =============================================================================
# Shannon — OpenAI Streaming Integration
#
# Monitors entropy of token distributions in real-time via OpenAI's
# streaming API with logprobs enabled.
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import dataclasses
from typing import Any, Generator

import numpy as np

from shannon.detector import CollapseEvent, ShannonCollapseDetector


@dataclasses.dataclass(frozen=True, slots=True)
class StreamEvent:
    """A single token event from a monitored stream."""
    token: str
    entropy: float
    delta_h: float
    collapse_score: float
    is_collapsed: bool


def monitor_openai_stream(
    client: Any,
    detector: ShannonCollapseDetector | None = None,
    stop_on_collapse: bool = False,
    top_logprobs: int = 20,
    **create_kwargs: Any,
) -> Generator[StreamEvent, None, None]:
    """Monitor entropy of an OpenAI streaming completion.

    Forces ``logprobs=True`` and ``stream=True`` in the API call.
    Feeds token log-probabilities to the detector each chunk.

    Parameters
    ----------
    client : openai.OpenAI
        An initialized OpenAI client.
    detector : ShannonCollapseDetector, optional
        Detector instance. Created with defaults if not provided.
    stop_on_collapse : bool
        If True, stop iterating when collapse is detected.
    top_logprobs : int
        Number of top log-probabilities to request (max 20).
    **create_kwargs
        Additional kwargs passed to ``client.chat.completions.create()``.
        Must include ``model`` and ``messages`` at minimum.

    Yields
    ------
    StreamEvent
        Per-token entropy information.

    Examples
    --------
    >>> from openai import OpenAI
    >>> from shannon.integrations.openai_stream import monitor_openai_stream
    >>> client = OpenAI()
    >>> for event in monitor_openai_stream(
    ...     client,
    ...     model="gpt-4",
    ...     messages=[{"role": "user", "content": "Hello"}],
    ... ):
    ...     print(f"{event.token:>15s}  H={event.entropy:.2f}")
    """
    if detector is None:
        detector = ShannonCollapseDetector()

    create_kwargs["stream"] = True
    create_kwargs["logprobs"] = True
    create_kwargs["stream_options"] = {"include_usage": True}
    if "top_logprobs" not in create_kwargs:
        create_kwargs["top_logprobs"] = top_logprobs

    stream = client.chat.completions.create(**create_kwargs)

    for chunk in stream:
        if not chunk.choices:
            continue

        choice = chunk.choices[0]
        if choice.logprobs is None or choice.logprobs.content is None:
            continue

        for token_logprobs in choice.logprobs.content:
            token_text = token_logprobs.token

            if token_logprobs.top_logprobs:
                lps = np.array(
                    [tlp.logprob for tlp in token_logprobs.top_logprobs],
                    dtype=np.float64,
                )
                res = detector.add_logprobs(lps)
            else:
                # No alternatives reported → degenerate one-hot distribution,
                # H = 0 bits. Goes through the public API so both the Python
                # and C++ backends stay in sync.
                res = detector.add_probs(np.array([1.0], dtype=np.float64))

            event = StreamEvent(
                token=token_text,
                entropy=res.entropy,
                delta_h=detector.delta_h,
                collapse_score=detector.collapse_score,
                is_collapsed=detector.is_collapsed,
            )
            yield event

            if stop_on_collapse and detector.is_collapsed:
                return
