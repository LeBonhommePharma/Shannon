#!/usr/bin/env python3
# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""
Example: Entropy collapse detection with Anthropic Claude streaming API.

Requires: pip install anthropic shannon-entropy
Set ANTHROPIC_API_KEY in your environment.

Note: As of 2026, Anthropic's API does not expose per-token logprobs.
This example demonstrates the pattern using estimated entropy from
token-level confidence signals. When logprobs become available,
switch to detector.add_logprobs() for exact computation.
"""

from __future__ import annotations

import os

import numpy as np

from shannon import ShannonCollapseDetector


def on_collapse(result):
    print(
        f"\n>>> ENTROPY COLLAPSE at token {result.token_index}: "
        f"H={result.entropy:.3f} bits, delta={result.delta:.3f}"
    )


def main():
    try:
        import anthropic
    except ImportError:
        print("Install anthropic: pip install anthropic")
        return

    client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))

    detector = ShannonCollapseDetector(
        window_size=8,
        threshold=-3.2,
        callback=on_collapse,
    )

    print("Prompt: 'Explain the halting problem.'")
    print("Monitoring entropy via synthetic logits estimation...\n")

    # Anthropic streaming — when logprobs become available, use them directly.
    # For now, we demonstrate with synthetic logit estimation from token lengths.
    with client.messages.stream(
        model="claude-sonnet-4-20250514",
        max_tokens=512,
        messages=[{"role": "user", "content": "Explain the halting problem."}],
    ) as stream:
        for text in stream.text_stream:
            # Synthetic entropy estimation: use character-level variation
            # as a proxy. Replace with actual logprobs when API supports them.
            char_counts = np.zeros(256, dtype=np.float64)
            for ch in text:
                char_counts[ord(ch) % 256] += 1
            if char_counts.sum() > 0:
                # Convert counts to pseudo-logits
                logits = np.log(char_counts + 1e-10)
                result = detector.add_logits(logits)
                print(f"'{text}' H={result.entropy:.3f}", end="  ")

    print(f"\n\nTotal steps: {len(detector.trace)}")
    print(f"Mean entropy: {np.mean(detector.trace):.3f} bits")


if __name__ == "__main__":
    main()
