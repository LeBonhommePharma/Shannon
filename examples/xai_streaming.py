#!/usr/bin/env python3
# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""
Example: Real-time entropy collapse detection with xAI (Grok) streaming API.

xAI is OpenAI-compatible — point the OpenAI SDK at api.x.ai:

    export XAI_API_KEY=xai-...          # https://console.x.ai
    # optional: export GROK_API_KEY=xai-...
    # optional: export XAI_MODEL=grok-3

    python examples/xai_streaming.py

Requires: pip install openai shannon-entropy

Note: logprobs / top_logprobs are not supported on grok-4.20 and newer
(xAI silently ignores them). Use a model that still returns top_logprobs
for true entropy monitoring.
"""

from __future__ import annotations

import os
import sys

import numpy as np

from shannon import ShannonCollapseDetector

XAI_BASE_URL = "https://api.x.ai/v1"
DEFAULT_MODEL = os.environ.get("XAI_MODEL", "grok-3")


def _api_key() -> str | None:
    return os.environ.get("XAI_API_KEY") or os.environ.get("GROK_API_KEY")


def on_collapse(result):
    print(
        f"\n>>> ENTROPY COLLAPSE at token {result.token_index}: "
        f"H={result.entropy:.3f} bits, delta={result.delta:.3f}, "
        f"z={result.z_score:.2f}"
    )


def main() -> None:
    try:
        from openai import OpenAI
    except ImportError:
        print("Install openai: pip install openai")
        return

    key = _api_key()
    if not key:
        print(
            "Missing API key. Set one of:\n"
            "  export XAI_API_KEY=xai-...\n"
            "  export GROK_API_KEY=xai-...\n"
            "Create a key at https://console.x.ai",
            file=sys.stderr,
        )
        sys.exit(1)

    client = OpenAI(api_key=key, base_url=XAI_BASE_URL)

    detector = ShannonCollapseDetector(
        window_size=8,
        threshold=-3.2,
        callback=on_collapse,
    )

    prompt = "Explain quantum entanglement step by step."
    print(f"Model: {DEFAULT_MODEL}")
    print(f"Base URL: {XAI_BASE_URL}")
    print(f"Prompt: {prompt!r}")
    print("Monitoring entropy in real-time...\n")

    stream = client.chat.completions.create(
        model=DEFAULT_MODEL,
        messages=[{"role": "user", "content": prompt}],
        stream=True,
        logprobs=True,
        top_logprobs=20,
    )

    saw_logprobs = False
    for chunk in stream:
        choice = chunk.choices[0] if chunk.choices else None
        if choice is None:
            continue

        token_text = choice.delta.content or ""

        # Extract logprobs from the streaming response (OpenAI-compatible).
        if choice.logprobs and choice.logprobs.content:
            for token_logprob in choice.logprobs.content:
                top = token_logprob.top_logprobs
                if not top:
                    continue
                saw_logprobs = True
                logprobs = np.array([t.logprob for t in top], dtype=np.float64)
                result = detector.add_logprobs(logprobs)
                label = token_logprob.token or token_text
                print(
                    f"'{label}' H={result.entropy:.3f} "
                    f"delta={result.delta:+.3f}",
                    end="  ",
                )
        elif token_text:
            # Stream without logprobs: print tokens so the demo still shows
            # progress on models that ignore logprobs.
            sys.stdout.write(token_text)
            sys.stdout.flush()

    print()
    if not saw_logprobs:
        print(
            "\nNo logprobs in the stream. grok-4.20+ ignore logprobs/"
            "top_logprobs — set XAI_MODEL to a model that still returns them "
            "(https://docs.x.ai/developers/models)."
        )
        return

    print(f"\nTotal tokens: {len(detector.trace)}")
    print(f"Mean entropy: {np.mean(detector.trace):.3f} bits")


if __name__ == "__main__":
    main()
