#!/usr/bin/env python3
"""Shannon + Anthropic — Streaming entropy monitoring demo.

Usage:
    export ANTHROPIC_API_KEY=sk-ant-...
    python examples/anthropic_demo.py "Explain the Van't Hoff equation"

Note: Anthropic's API does not yet expose token logprobs in streaming.
This demo shows the streaming interface structure; entropy values will
be None until logprobs become available.
"""

from __future__ import annotations

import sys

from anthropic import Anthropic

from shannon import ShannonCollapseDetector
from shannon.integrations.anthropic_stream import monitor_anthropic_stream


def main() -> None:
    prompt = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "What is configurational entropy?"
    client = Anthropic()
    detector = ShannonCollapseDetector(window_size=8, collapse_threshold=-3.2)

    print(f"Monitoring: {prompt}")
    print("-" * 70)

    for event in monitor_anthropic_stream(
        client,
        detector=detector,
        model="claude-sonnet-4-20250514",
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
    ):
        sys.stdout.write(event.text)
        sys.stdout.flush()

    print("\n" + "-" * 70)
    print("Note: Token-level entropy monitoring pending Anthropic logprobs API support.")


if __name__ == "__main__":
    main()
