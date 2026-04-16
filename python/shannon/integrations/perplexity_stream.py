# =============================================================================
# Shannon — Perplexity Streaming Integration
#
# Monitors entropy of token distributions via Perplexity's OpenAI-compatible API.
# Perplexity (Sonar models) uses the same chat completions format.
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import dataclasses
from typing import Any, Generator

import numpy as np

from shannon.detector import ShannonCollapseDetector


@dataclasses.dataclass(frozen=True, slots=True)
class PerplexityStreamEvent:
    """A single token event from a monitored Perplexity stream."""
    token: str
    entropy: float
    delta_h: float
    collapse_score: float
    is_collapsed: bool
    citations: list[str] | None


def monitor_perplexity_stream(
    client: Any,
    detector: ShannonCollapseDetector | None = None,
    stop_on_collapse: bool = False,
    top_logprobs: int = 20,
    **create_kwargs: Any,
) -> Generator[PerplexityStreamEvent, None, None]:
    """Monitor entropy of a Perplexity streaming completion.

    Perplexity uses an OpenAI-compatible API with additional citation metadata.
    This integration extracts logprobs for entropy monitoring and preserves
    citation information.

    Parameters
    ----------
    client : openai.OpenAI
        An OpenAI client configured with Perplexity's base_url:
        ``OpenAI(api_key=PPLX_API_KEY, base_url="https://api.perplexity.ai")``
    detector : ShannonCollapseDetector, optional
        Detector instance. Created with defaults if not provided.
    stop_on_collapse : bool
        If True, stop iterating when collapse is detected.
    top_logprobs : int
        Number of top log-probabilities to request.
    **create_kwargs
        Additional kwargs for ``client.chat.completions.create()``.
        Must include ``model`` (e.g., "sonar-pro") and ``messages``.

    Yields
    ------
    PerplexityStreamEvent

    Examples
    --------
    >>> from openai import OpenAI
    >>> from shannon.integrations.perplexity_stream import monitor_perplexity_stream
    >>> client = OpenAI(
    ...     api_key="pplx-...",
    ...     base_url="https://api.perplexity.ai"
    ... )
    >>> for event in monitor_perplexity_stream(
    ...     client,
    ...     model="sonar-pro",
    ...     messages=[{"role": "user", "content": "What is entropy?"}],
    ... ):
    ...     print(f"{event.token:>15s}  H={event.entropy:.2f}")
    """
    if detector is None:
        detector = ShannonCollapseDetector()

    create_kwargs["stream"] = True
    create_kwargs["logprobs"] = True
    if "top_logprobs" not in create_kwargs:
        create_kwargs["top_logprobs"] = top_logprobs

    stream = client.chat.completions.create(**create_kwargs)

    citations = None
    for chunk in stream:
        # Perplexity includes citations in chunk metadata
        if hasattr(chunk, "citations"):
            citations = chunk.citations

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
                H = detector.add_logprobs(lps)
            else:
                H = 0.0
                detector._push_and_check(H)

            event = PerplexityStreamEvent(
                token=token_text,
                entropy=H,
                delta_h=detector.delta_h,
                collapse_score=detector.collapse_score,
                is_collapsed=detector.is_collapsed,
                citations=citations,
            )
            yield event

            if stop_on_collapse and detector.is_collapsed:
                return
