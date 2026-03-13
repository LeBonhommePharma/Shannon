#!/usr/bin/env python3
"""Shannon + OpenAI — Real-time entropy monitoring demo.

Usage:
    export OPENAI_API_KEY=sk-...
    python examples/openai_demo.py "Explain quantum entanglement"
"""

from __future__ import annotations

import sys

from openai import OpenAI

from shannon import ShannonCollapseDetector
from shannon.integrations.openai_stream import monitor_openai_stream


def main() -> None:
    prompt = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "What is Shannon entropy?"
    client = OpenAI()
    detector = ShannonCollapseDetector(
        window_size=8,
        collapse_threshold=-3.2,
        on_collapse=lambda e: print(
            f"\n!! ENTROPY COLLAPSE at token {e.token_index} "
            f"(H={e.entropy:.3f}, dH={e.delta_h:.3f}, score={e.collapse_score:.2f})\n"
        ),
    )

    print(f"Monitoring: {prompt}")
    print("-" * 70)

    full_text = []
    for event in monitor_openai_stream(
        client,
        detector=detector,
        model="gpt-4",
        messages=[{"role": "user", "content": prompt}],
    ):
        full_text.append(event.token)
        sys.stdout.write(event.token)
        sys.stdout.flush()

    print("\n" + "-" * 70)
    print(f"Tokens: {detector.token_count}")
    print(f"Mean entropy: {sum(detector.entropy_trace) / len(detector.entropy_trace):.3f} bits")
    print(f"Min entropy: {min(detector.entropy_trace):.3f} bits")
    print(f"Final collapse score: {detector.collapse_score:.3f}")


if __name__ == "__main__":
    main()
