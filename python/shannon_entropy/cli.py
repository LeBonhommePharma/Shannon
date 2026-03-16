# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""
shannon-monitor CLI — real-time entropy collapse monitoring for LLM streams.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import TextIO

from shannon_entropy.detector import ShannonCollapseDetector, CollapseResult


def _on_collapse(result: CollapseResult) -> None:
    """Default alert handler: print to stderr."""
    print(
        f"\033[91m[COLLAPSE]\033[0m token={result.token_index} "
        f"H={result.entropy:.3f} bits  delta={result.delta:.3f}  "
        f"z={result.z_score:.2f}",
        file=sys.stderr,
    )


def monitor_jsonl(
    stream: TextIO,
    field: str,
    window_size: int,
    threshold: float,
    quiet: bool,
) -> int:
    """Monitor a JSONL stream of token distributions.

    Each line should be a JSON object with a field containing an array
    of floats (logits, probs, or logprobs).

    Returns the number of collapse events detected.
    """
    collapse_count = 0

    def _callback(r: CollapseResult) -> None:
        nonlocal collapse_count
        collapse_count += 1
        if not quiet:
            _on_collapse(r)

    detector = ShannonCollapseDetector(
        window_size=window_size,
        threshold=threshold,
        callback=_callback,
    )

    for line_no, line in enumerate(stream, 1):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            print(f"Warning: skipping malformed JSON on line {line_no}", file=sys.stderr)
            continue

        values = obj.get(field)
        if values is None:
            continue

        if field == "probs":
            result = detector.add_probs(values)
        elif field == "logprobs":
            result = detector.add_logprobs(values)
        else:
            result = detector.add_logits(values)

        if not quiet:
            flag = " ***" if result.collapsed else ""
            print(
                f"token={result.token_index:5d}  "
                f"H={result.entropy:7.3f}  "
                f"mean={result.window_mean:7.3f}  "
                f"delta={result.delta:+7.3f}{flag}"
            )

    return collapse_count


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="shannon-monitor",
        description="Real-time Shannon entropy collapse detection for LLM streams.",
    )
    parser.add_argument(
        "input",
        nargs="?",
        type=argparse.FileType("r"),
        default=sys.stdin,
        help="Input JSONL file (default: stdin)",
    )
    parser.add_argument(
        "-f", "--field",
        default="logits",
        choices=["logits", "probs", "logprobs"],
        help="JSON field containing the distribution (default: logits)",
    )
    parser.add_argument(
        "-w", "--window-size",
        type=int,
        default=8,
        help="Sliding window size (default: 8)",
    )
    parser.add_argument(
        "-t", "--threshold",
        type=float,
        default=-3.2,
        help="Collapse threshold in bits (default: -3.2)",
    )
    parser.add_argument(
        "-q", "--quiet",
        action="store_true",
        help="Only output final collapse count",
    )

    args = parser.parse_args()
    count = monitor_jsonl(
        stream=args.input,
        field=args.field,
        window_size=args.window_size,
        threshold=args.threshold,
        quiet=args.quiet,
    )

    if args.quiet:
        print(count)

    sys.exit(1 if count > 0 else 0)


if __name__ == "__main__":
    main()
