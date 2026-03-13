#!/usr/bin/env python3
# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""
Example: Real-time entropy collapse detection with OpenAI streaming API.

Requires: pip install openai shannon-entropy
Set OPENAI_API_KEY in your environment.
"""

from __future__ import annotations

import os

import numpy as np

from shannon_entropy import ShannonCollapseDetector


def on_collapse(result):
    print(
        f"\n>>> ENTROPY COLLAPSE at token {result.token_index}: "
        f"H={result.entropy:.3f} bits, delta={result.delta:.3f}, "
        f"z={result.z_score:.2f}"
    )


def main():
    try:
        from openai import OpenAI
    except ImportError:
        print("Install openai: pip install openai")
        return

    client = OpenAI(api_key=os.environ.get("OPENAI_API_KEY"))

    detector = ShannonCollapseDetector(
        window_size=8,
        threshold=-3.2,
        callback=on_collapse,
    )

    print("Prompt: 'Explain quantum entanglement step by step.'")
    print("Monitoring entropy in real-time...\n")

    stream = client.chat.completions.create(
        model="gpt-4",
        messages=[{"role": "user", "content": "Explain quantum entanglement step by step."}],
        stream=True,
        logprobs=True,
        top_logprobs=20,
    )

    for chunk in stream:
        choice = chunk.choices[0] if chunk.choices else None
        if choice is None or choice.delta.content is None:
            continue

        token_text = choice.delta.content

        # Extract logprobs from the streaming response
        if choice.logprobs and choice.logprobs.content:
            for token_logprob in choice.logprobs.content:
                top = token_logprob.top_logprobs
                if top:
                    logprobs = np.array([t.logprob for t in top], dtype=np.float64)
                    result = detector.add_logprobs(logprobs)
                    print(
                        f"'{token_text}' H={result.entropy:.3f} "
                        f"delta={result.delta:+.3f}",
                        end="  ",
                    )

    print(f"\n\nTotal tokens: {len(detector.trace)}")
    print(f"Mean entropy: {np.mean(detector.trace):.3f} bits")


if __name__ == "__main__":
    main()
