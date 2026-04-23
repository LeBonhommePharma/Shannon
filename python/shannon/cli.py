# =============================================================================
# shannon-monitor CLI — Real-time LLM entropy monitoring
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import argparse
import json
import sys
from typing import TextIO

import numpy as np

from shannon.detector import CollapseResult, ShannonCollapseDetector


# ── Shared formatters ─────────────────────────────────────────────────────────


def _format_text(token_idx: int, token: str, H: float, delta_h: float,
                 score: float, collapsed: bool) -> str:
    marker = " !! COLLAPSE" if collapsed else ""
    return f"Token {token_idx:>4d}: {token:>20s}  H={H:6.3f}  dH={delta_h:+6.3f}  score={score:.2f}{marker}"


def _format_json(token_idx: int, token: str, H: float, delta_h: float,
                 score: float, collapsed: bool) -> str:
    return json.dumps({
        "token_index": token_idx,
        "token": token,
        "entropy": round(H, 4),
        "delta_h": round(delta_h, 4),
        "collapse_score": round(score, 4),
        "collapsed": collapsed,
    })


def _format_csv(token_idx: int, token: str, H: float, delta_h: float,
                score: float, collapsed: bool) -> str:
    token_escaped = token.replace('"', '""')
    return f'{token_idx},"{token_escaped}",{H:.4f},{delta_h:.4f},{score:.4f},{collapsed}'


_FORMATTERS = {
    "text": _format_text,
    "json": _format_json,
    "csv": _format_csv,
}


# ── JSONL monitoring (legacy mode) ───────────────────────────────────────────


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


# ── Subcommands ────────────────────────────────────────────────────────────────


def cmd_stdin(args: argparse.Namespace) -> None:
    """Process JSONL from stdin. Each line: {"logprobs": [...]} or {"probs": [...]}."""
    detector = ShannonCollapseDetector(
        window_size=args.window,
        threshold=args.threshold,
    )
    fmt = _FORMATTERS[args.format]

    if args.format == "csv":
        print("token_index,token,entropy,delta_h,collapse_score,collapsed")

    for line_num, line in enumerate(sys.stdin):
        line = line.strip()
        if not line:
            continue

        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            print(f"Warning: skipping malformed JSON at line {line_num + 1}", file=sys.stderr)
            continue

        token = data.get("token", "")

        if "logprobs" in data:
            lps = np.array(data["logprobs"], dtype=np.float64)
            result = detector.add_logprobs(lps)
        elif "probs" in data:
            probs = np.array(data["probs"], dtype=np.float64)
            result = detector.add_probs(probs)
        elif "logits" in data:
            logits = np.array(data["logits"], dtype=np.float64)
            result = detector.add_logits(logits)
        else:
            continue

        print(fmt(
            result.token_index,
            token,
            result.entropy,
            result.delta,
            abs(result.delta / detector.threshold) if abs(detector.threshold) > 1e-15 else 0.0,
            result.collapsed,
        ))


def cmd_openai(args: argparse.Namespace) -> None:
    """Wrap an OpenAI API call and monitor entropy."""
    try:
        from openai import OpenAI
    except ImportError:
        print("Error: openai package not installed. Run: pip install shannon-entropy[openai]",
              file=sys.stderr)
        sys.exit(1)

    from shannon.integrations.openai_stream import monitor_openai_stream

    client = OpenAI()
    detector = ShannonCollapseDetector(
        window_size=args.window,
        threshold=args.threshold,
    )
    fmt = _FORMATTERS[args.format]

    if args.format == "csv":
        print("token_index,token,entropy,delta_h,collapse_score,collapsed")

    prompt = " ".join(args.prompt)
    for event in monitor_openai_stream(
        client,
        detector=detector,
        model=args.model,
        messages=[{"role": "user", "content": prompt}],
    ):
        print(fmt(
            detector.token_count - 1,
            event.token,
            event.entropy,
            event.delta_h,
            event.collapse_score,
            event.is_collapsed,
        ))


def cmd_info(args: argparse.Namespace) -> None:
    """Print hardware and backend information."""
    import shannon
    print(f"Shannon v{shannon.__version__}")
    print(f"C++ core available: {shannon._HAS_CORE}")

    if shannon._HAS_CORE:
        info = shannon.get_hardware_info()
        print(f"Active backend: {info.active_backend}")
        print(f"AVX-512: {info.has_avx512}")
        print(f"AVX2: {info.has_avx2}")
        print(f"OpenMP: {info.has_openmp}")
        print(f"CUDA: {info.has_cuda}")
        print(f"Metal: {info.has_metal}")

        matrix = shannon.ShannonEnergyMatrix.instance()
        print(f"Energy matrix: {matrix.DIM}x{matrix.DIM} ({matrix.TOTAL_PARAMS} parameters)")
        print(f"Non-zero parameters: {matrix.nonzero_count()}")
    else:
        from shannon._numba_fallback import get_backend
        print(f"Fallback backend: {get_backend()}")


# ── Main entry point ──────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="shannon-monitor",
        description="Real-time Shannon entropy collapse detection for LLM streams",
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # stdin subcommand
    stdin_parser = subparsers.add_parser(
        "stdin",
        help="Read JSONL from stdin (each line: {\"logprobs\": [...], \"token\": \"...\"})",
    )

    # openai subcommand
    openai_parser = subparsers.add_parser(
        "openai",
        help="Monitor an OpenAI API call in real-time",
    )
    openai_parser.add_argument("--model", default="gpt-4", help="Model name")
    openai_parser.add_argument("prompt", nargs="+", help="Prompt text")

    # info subcommand
    info_parser = subparsers.add_parser(
        "info",
        help="Print hardware acceleration and backend info",
    )

    # Common flags for stdin and openai
    for p in [stdin_parser, openai_parser]:
        p.add_argument("--threshold", type=float, default=-3.2,
                        help="Collapse threshold in bits/token (default: -3.2)")
        p.add_argument("--window", type=int, default=8,
                        help="Sliding window size (default: 8)")
        p.add_argument("--format", choices=["text", "json", "csv"], default="text",
                        help="Output format (default: text)")

    args = parser.parse_args()

    if args.command == "stdin":
        cmd_stdin(args)
    elif args.command == "openai":
        cmd_openai(args)
    elif args.command == "info":
        cmd_info(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
