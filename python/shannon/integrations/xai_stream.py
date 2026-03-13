# =============================================================================
# Shannon — xAI (Grok) Streaming Integration
#
# Monitors entropy of token distributions via xAI's OpenAI-compatible API.
# xAI uses the same API format as OpenAI with logprobs support.
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
class XAIStreamEvent:
    """A single token event from a monitored xAI stream."""
    token: str
    entropy: float
    delta_h: float
    collapse_score: float
    is_collapsed: bool


def monitor_xai_stream(
    client: Any,
    detector: ShannonCollapseDetector | None = None,
    stop_on_collapse: bool = False,
    top_logprobs: int = 20,
    **create_kwargs: Any,
) -> Generator[XAIStreamEvent, None, None]:
    """Monitor entropy of an xAI (Grok) streaming completion.

    xAI uses an OpenAI-compatible API, so this integration works identically
    to the OpenAI integration but with the xAI base URL and models.

    Parameters
    ----------
    client : openai.OpenAI
        An OpenAI client configured with xAI's base_url:
        ``OpenAI(api_key=XAI_API_KEY, base_url="https://api.x.ai/v1")``
    detector : ShannonCollapseDetector, optional
        Detector instance. Created with defaults if not provided.
    stop_on_collapse : bool
        If True, stop iterating when collapse is detected.
    top_logprobs : int
        Number of top log-probabilities to request.
    **create_kwargs
        Additional kwargs for ``client.chat.completions.create()``.
        Must include ``model`` (e.g., "grok-2") and ``messages``.

    Yields
    ------
    XAIStreamEvent

    Examples
    --------
    >>> from openai import OpenAI
    >>> from shannon.integrations.xai_stream import monitor_xai_stream
    >>> client = OpenAI(
    ...     api_key="xai-...",
    ...     base_url="https://api.x.ai/v1"
    ... )
    >>> for event in monitor_xai_stream(
    ...     client,
    ...     model="grok-2",
    ...     messages=[{"role": "user", "content": "Hello"}],
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
                H = detector.add_logprobs(lps)
            else:
                H = 0.0
                detector._push_and_check(H)

            event = XAIStreamEvent(
                token=token_text,
                entropy=H,
                delta_h=detector.delta_h,
                collapse_score=detector.collapse_score,
                is_collapsed=detector.is_collapsed,
            )
            yield event

            if stop_on_collapse and detector.is_collapsed:
                return
