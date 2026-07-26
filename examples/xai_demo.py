#!/usr/bin/env python3
"""Shannon + xAI (Grok) — Real-time entropy monitoring demo.

xAI's Chat Completions API is OpenAI-compatible. Auth and client setup:

    export XAI_API_KEY=xai-...          # from https://console.x.ai
    # optional fallback also accepted by Shannon hub:
    # export GROK_API_KEY=xai-...

    python examples/xai_demo.py "Explain quantum entanglement"

Requires: pip install openai shannon-entropy

Note: logprobs / top_logprobs are required for true entropy monitoring.
xAI silently ignores those fields on models grok-4.20 and newer; use a
model that still returns top_logprobs (override with XAI_MODEL).
"""

from __future__ import annotations

import os
import sys

from openai import OpenAI

from shannon import ShannonCollapseDetector
from shannon.integrations.xai_stream import monitor_xai_stream

XAI_BASE_URL = "https://api.x.ai/v1"
# Prefer a model family known to still return logprobs when available.
DEFAULT_MODEL = os.environ.get("XAI_MODEL", "grok-3")


def _api_key() -> str | None:
    """Resolve xAI API key from the standard env vars (hub-compatible)."""
    return os.environ.get("XAI_API_KEY") or os.environ.get("GROK_API_KEY")


def main() -> None:
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

    prompt = (
        " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "What is Shannon entropy?"
    )
    client = OpenAI(api_key=key, base_url=XAI_BASE_URL)
    detector = ShannonCollapseDetector(
        window_size=8,
        collapse_threshold=-3.2,
        on_collapse=lambda e: print(
            f"\n!! ENTROPY COLLAPSE at token {e.token_index} "
            f"(H={e.entropy:.3f}, dH={e.delta_h:.3f}, score={e.collapse_score:.2f})\n"
        ),
    )

    print(f"Model: {DEFAULT_MODEL}")
    print(f"Base URL: {XAI_BASE_URL}")
    print(f"Monitoring: {prompt}")
    print("-" * 70)

    full_text: list[str] = []
    for event in monitor_xai_stream(
        client,
        detector=detector,
        model=DEFAULT_MODEL,
        messages=[{"role": "user", "content": prompt}],
    ):
        full_text.append(event.token)
        sys.stdout.write(event.token)
        sys.stdout.flush()

    print("\n" + "-" * 70)
    if not detector.entropy_trace:
        print(
            "No logprobs received. If you used grok-4.20+, xAI ignores "
            "logprobs/top_logprobs — set XAI_MODEL to a model that still "
            "returns them (see https://docs.x.ai/developers/models)."
        )
        return

    print(f"Tokens: {detector.token_count}")
    print(
        f"Mean entropy: "
        f"{sum(detector.entropy_trace) / len(detector.entropy_trace):.3f} bits"
    )
    print(f"Min entropy: {min(detector.entropy_trace):.3f} bits")
    print(f"Final collapse score: {detector.collapse_score:.3f}")


if __name__ == "__main__":
    main()
