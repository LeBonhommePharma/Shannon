# =============================================================================
# Shannon — Anthropic Streaming Integration
#
# Forward-looking integration for Anthropic's streaming API.
# Currently provides character-level entropy estimation from token
# probabilities when available.
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
class AnthropicStreamEvent:
    """A text event from a monitored Anthropic stream."""
    text: str
    entropy: float | None
    delta_h: float
    collapse_score: float
    is_collapsed: bool


def monitor_anthropic_stream(
    client: Any,
    detector: ShannonCollapseDetector | None = None,
    stop_on_collapse: bool = False,
    **create_kwargs: Any,
) -> Generator[AnthropicStreamEvent, None, None]:
    """Monitor entropy of an Anthropic streaming message.

    Uses ``client.messages.stream()`` context manager. When token-level
    logprobs become available in the Anthropic API, this integration
    will feed them directly to the detector. Until then, it yields
    text events with entropy=None.

    Parameters
    ----------
    client : anthropic.Anthropic
        An initialized Anthropic client.
    detector : ShannonCollapseDetector, optional
        Detector instance. Created with defaults if not provided.
    stop_on_collapse : bool
        If True, stop iterating when collapse is detected.
    **create_kwargs
        Additional kwargs passed to ``client.messages.stream()``.
        Must include ``model``, ``max_tokens``, and ``messages``.

    Yields
    ------
    AnthropicStreamEvent

    Examples
    --------
    >>> from anthropic import Anthropic
    >>> from shannon.integrations.anthropic_stream import monitor_anthropic_stream
    >>> client = Anthropic()
    >>> for event in monitor_anthropic_stream(
    ...     client,
    ...     model="claude-sonnet-4-20250514",
    ...     max_tokens=1024,
    ...     messages=[{"role": "user", "content": "Hello"}],
    ... ):
    ...     print(f"text='{event.text}' H={event.entropy}")
    """
    if detector is None:
        detector = ShannonCollapseDetector()

    with client.messages.stream(**create_kwargs) as stream:
        for text in stream.text_stream:
            # Anthropic API does not yet expose token logprobs in streaming.
            # When it does, extract logprobs and call detector.add_logprobs().
            # For now, yield with entropy=None to maintain the streaming interface.
            event = AnthropicStreamEvent(
                text=text,
                entropy=None,
                delta_h=detector.delta_h,
                collapse_score=detector.collapse_score,
                is_collapsed=detector.is_collapsed,
            )
            yield event

            if stop_on_collapse and detector.is_collapsed:
                return
