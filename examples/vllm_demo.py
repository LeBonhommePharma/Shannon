#!/usr/bin/env python3
"""Shannon + vLLM — Local model entropy monitoring demo.

Usage:
    pip install vllm
    python examples/vllm_demo.py

Requires a GPU with sufficient VRAM for the model.
"""

from __future__ import annotations

from vllm import LLM, SamplingParams

from shannon import ShannonCollapseDetector
from shannon.integrations.vllm_local import monitor_vllm_output


def main() -> None:
    print("Loading model...")
    llm = LLM(model="meta-llama/Llama-3.1-8B-Instruct")

    params = SamplingParams(
        temperature=0.7,
        max_tokens=256,
        logprobs=50,  # Request top-50 logprobs for entropy computation
    )

    prompts = [
        "Explain the relationship between Shannon entropy and thermodynamic entropy.",
        "Write a poem about the heat death of the universe.",
    ]

    print("Generating...")
    outputs = llm.generate(prompts, params)

    detector = ShannonCollapseDetector(
        window_size=8,
        collapse_threshold=-3.2,
        on_collapse=lambda e: print(
            f"  !! COLLAPSE at token {e.token_index} "
            f"(H={e.entropy:.3f}, score={e.collapse_score:.2f})"
        ),
    )

    for i, output in enumerate(outputs):
        print(f"\n{'=' * 60}")
        print(f"Prompt: {prompts[i]}")
        print("-" * 60)

        detector.reset()
        events = monitor_vllm_output(output, detector=detector)

        for event in events:
            status = " !!" if event.is_collapsed else ""
            print(f"  {event.token_text:>15s}  H={event.entropy:.3f}  "
                  f"dH={event.delta_h:+.3f}{status}")

        print(f"\nTokens: {detector.token_count}")
        if detector.entropy_trace:
            print(f"Mean H: {sum(detector.entropy_trace) / len(detector.entropy_trace):.3f}")


if __name__ == "__main__":
    main()
