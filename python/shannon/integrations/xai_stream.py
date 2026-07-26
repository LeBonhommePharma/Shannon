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

from shannon.detector import ShannonCollapseDetector
from shannon.integrations.logprob_feed import feed_token_logprobs


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
        Must include ``model`` (e.g., "grok-3") and ``messages``.

    Yields
    ------
    XAIStreamEvent

    Examples
    --------
    >>> import os
    >>> from openai import OpenAI
    >>> from shannon.integrations.xai_stream import monitor_xai_stream
    >>> client = OpenAI(
    ...     api_key=os.environ["XAI_API_KEY"],  # or GROK_API_KEY
    ...     base_url="https://api.x.ai/v1",
    ... )
    >>> for event in monitor_xai_stream(
    ...     client,
    ...     model="grok-3",  # logprobs ignored on grok-4.20+
    ...     messages=[{"role": "user", "content": "Hello"}],
    ... ):
    ...     print(f"{event.token:>15s}  H={event.entropy:.2f}")

    Auth
    ----
    Create a key at https://console.x.ai and export ``XAI_API_KEY`` (preferred)
    or ``GROK_API_KEY`` (Shannon hub fallback). See ``examples/xai_demo.py``.
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

            # Missing top_logprobs → absent, not collapse (never one-hot H=0).
            res = feed_token_logprobs(detector, token_logprobs.top_logprobs)
            if res is None:
                continue

            event = XAIStreamEvent(
                token=token_text,
                entropy=res.entropy,
                delta_h=detector.delta_h,
                collapse_score=detector.collapse_score,
                is_collapsed=detector.is_collapsed,
            )
            yield event

            if stop_on_collapse and detector.is_collapsed:
                return
