#!/usr/bin/env python3
# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""
Example: Entropy collapse detection with vLLM / Hugging Face local models.

Requires: pip install vllm shannon-entropy
         (or: pip install transformers torch shannon-entropy)
"""

from __future__ import annotations

import numpy as np

from shannon_entropy import ShannonCollapseDetector


def on_collapse(result):
    print(
        f"\n>>> COLLAPSE at token {result.token_index}: "
        f"H={result.entropy:.3f}, delta={result.delta:.3f}, z={result.z_score:.2f}"
    )


def run_vllm():
    """Run with vLLM (GPU-accelerated inference)."""
    try:
        from vllm import LLM, SamplingParams
    except ImportError:
        print("Install vLLM: pip install vllm")
        return

    detector = ShannonCollapseDetector(window_size=8, threshold=-3.2, callback=on_collapse)

    llm = LLM(model="meta-llama/Llama-3.1-8B-Instruct")
    params = SamplingParams(
        max_tokens=256,
        temperature=0.7,
        logprobs=50,  # Request top-50 logprobs
    )

    outputs = llm.generate(["Explain why AI safety matters."], params)

    for output in outputs:
        for token_out in output.outputs[0].logprobs:
            if token_out:
                logprobs = np.array(
                    [v.logprob for v in token_out.values()], dtype=np.float64
                )
                result = detector.add_logprobs(logprobs)
                print(f"H={result.entropy:.3f} delta={result.delta:+.3f}", end="  ")

    print(f"\n\nTotal tokens: {len(detector.trace)}")


def run_transformers():
    """Run with Hugging Face Transformers (CPU or GPU)."""
    try:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except ImportError:
        print("Install transformers: pip install transformers torch")
        return

    detector = ShannonCollapseDetector(window_size=8, threshold=-3.2, callback=on_collapse)

    model_name = "microsoft/DialoGPT-medium"
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    model = AutoModelForCausalLM.from_pretrained(model_name)

    input_text = "What is the meaning of life?"
    input_ids = tokenizer.encode(input_text, return_tensors="pt")

    with torch.no_grad():
        for _ in range(100):
            outputs = model(input_ids)
            logits = outputs.logits[0, -1, :].numpy().astype(np.float64)
            result = detector.add_logits(logits)

            # Greedy decode
            next_token = int(outputs.logits[0, -1, :].argmax())
            input_ids = torch.cat(
                [input_ids, torch.tensor([[next_token]])], dim=-1
            )

            token_text = tokenizer.decode([next_token])
            print(
                f"'{token_text}' H={result.entropy:.3f} "
                f"delta={result.delta:+.3f}",
                end="  ",
            )

            if next_token == tokenizer.eos_token_id:
                break

    print(f"\n\nTotal tokens: {len(detector.trace)}")
    print(f"Mean entropy: {np.mean(detector.trace):.3f} bits")


if __name__ == "__main__":
    import sys

    if "--transformers" in sys.argv:
        run_transformers()
    else:
        run_vllm()
