# =============================================================================
# Shannon — vLLM / Hugging Face Local Model Integration
#
# Monitors entropy of locally-served LLM token distributions.
# vLLM provides full vocabulary logprobs — the most natural integration.
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import dataclasses
from typing import Any

import numpy as np

from shannon.detector import CollapseEvent, ShannonCollapseDetector


@dataclasses.dataclass(frozen=True, slots=True)
class VLLMTokenEvent:
    """A single token event from vLLM output."""
    token_id: int
    token_text: str
    entropy: float
    delta_h: float
    collapse_score: float
    is_collapsed: bool


def monitor_vllm_output(
    outputs: Any,
    detector: ShannonCollapseDetector | None = None,
    vocab_size: int | None = None,
) -> list[VLLMTokenEvent]:
    """Monitor entropy from vLLM generation outputs.

    Extracts logprobs from vLLM ``RequestOutput`` objects and feeds
    them to the detector.

    Parameters
    ----------
    outputs : vllm.RequestOutput or list[vllm.RequestOutput]
        Output from ``llm.generate()``.
    detector : ShannonCollapseDetector, optional
        Detector instance. Created with defaults if not provided.
    vocab_size : int, optional
        Full vocabulary size for entropy normalization.

    Returns
    -------
    list[VLLMTokenEvent]
        Per-token entropy events.

    Examples
    --------
    >>> from vllm import LLM, SamplingParams
    >>> from shannon.integrations.vllm_local import monitor_vllm_output
    >>> llm = LLM(model="meta-llama/Llama-3-8B")
    >>> params = SamplingParams(logprobs=50, temperature=0.7)
    >>> outputs = llm.generate(["Hello, world!"], params)
    >>> events = monitor_vllm_output(outputs)
    >>> for e in events:
    ...     print(f"token={e.token_text:>15s}  H={e.entropy:.2f}  collapsed={e.is_collapsed}")
    """
    if detector is None:
        detector = ShannonCollapseDetector()

    # Normalize input
    if not isinstance(outputs, (list, tuple)):
        outputs = [outputs]

    events: list[VLLMTokenEvent] = []

    for request_output in outputs:
        for completion_output in request_output.outputs:
            if completion_output.logprobs is None:
                continue

            for step_idx, logprobs_dict in enumerate(completion_output.logprobs):
                # vLLM logprobs: dict[int, Logprob] where Logprob has .logprob
                lps = np.array(
                    [lp.logprob for lp in logprobs_dict.values()],
                    dtype=np.float64,
                )
                H = detector.add_logprobs(lps)

                # Get the selected token
                token_ids = list(logprobs_dict.keys())
                token_id = completion_output.token_ids[step_idx] if step_idx < len(completion_output.token_ids) else token_ids[0]

                # Get token text
                token_text = ""
                if token_id in logprobs_dict:
                    decoded = logprobs_dict[token_id].decoded_token
                    if decoded is not None:
                        token_text = decoded

                events.append(VLLMTokenEvent(
                    token_id=token_id,
                    token_text=token_text,
                    entropy=H,
                    delta_h=detector.delta_h,
                    collapse_score=detector.collapse_score,
                    is_collapsed=detector.is_collapsed,
                ))

    return events


def monitor_vllm_async(
    engine: Any,
    request_id: str,
    detector: ShannonCollapseDetector | None = None,
):
    """Async generator for monitoring vLLM AsyncLLMEngine output.

    Parameters
    ----------
    engine : vllm.AsyncLLMEngine
        The async engine instance.
    request_id : str
        The request ID to monitor.
    detector : ShannonCollapseDetector, optional

    Yields
    ------
    VLLMTokenEvent
    """
    import asyncio

    if detector is None:
        detector = ShannonCollapseDetector()

    async def _monitor():
        async for output in engine.generate(request_id):
            for completion in output.outputs:
                if completion.logprobs is None:
                    continue
                # Process only the latest logprob step
                if completion.logprobs:
                    latest = completion.logprobs[-1]
                    lps = np.array(
                        [lp.logprob for lp in latest.values()],
                        dtype=np.float64,
                    )
                    H = detector.add_logprobs(lps)
                    yield VLLMTokenEvent(
                        token_id=0,
                        token_text="",
                        entropy=H,
                        delta_h=detector.delta_h,
                        collapse_score=detector.collapse_score,
                        is_collapsed=detector.is_collapsed,
                    )

    return _monitor()
