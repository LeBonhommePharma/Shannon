# Shannon v2 Architecture

## System Overview

```
                        ┌─────────────────────────────┐
                        │       LLM Inference Engine    │
                        └──────┬──────────┬────────────┘
                               │          │
                     logits JSONL    shared memory / socket
                               │          │
                        ┌──────v──────────v────────────┐
                        │       Stream Ingestion        │
                        │  ┌─────────┐ ┌─────────────┐ │
                        │  │ Stdin   │ │ Socket/Shmem │ │
                        │  │ JSONL   │ │ (zero-copy)  │ │
                        │  └────┬────┘ └──────┬──────┘ │
                        └───────┼─────────────┼────────┘
                                │             │
                        ┌───────v─────────────v────────┐
                        │       TerminalAgent           │
                        │  orchestrates the full        │
                        │  detection pipeline           │
                        └───────┬──────────────────────┘
                                │
                ┌───────────────v───────────────┐
                │       CollapseDetector         │
                │  ┌──────────────────────────┐  │
                │  │ UnifiedDispatch           │  │
                │  │  ┌──────────────────────┐ │  │
                │  │  │ Entropy Kernel       │ │  │
                │  │  │ (scalar/OMP/SIMD/GPU)│ │  │
                │  │  └──────────┬───────────┘ │  │
                │  └────────────┼──────────────┘  │
                │               │ entropy (bits)   │
                │  ┌────────────v──────────────┐  │
                │  │ Sliding Window (W=8)      │  │
                │  │ mean, stddev, delta, z    │  │
                │  └────────────┬──────────────┘  │
                │               │                  │
                │     collapsed? delta < threshold │
                └───────────────┼──────────────────┘
                                │
                        ┌───────v──────────────┐
                        │   HandrailEngine      │
                        │  ┌─────────────────┐ │
                        │  │ Escalation Logic │ │
                        │  │ first / sustained│ │
                        │  │ + cooldown       │ │
                        │  └────────┬────────┘ │
                        │           │          │
                        │  ┌───v───v───v────┐  │
                        │  │log alert thr   │  │
                        │  │kill coredump   │  │
                        │  │webhook callback│  │
                        │  └────────────────┘  │
                        └──────────────────────┘
```

## Module Dependency Graph

```
terminal_agent.hpp
    ├── collapse_detector.hpp
    │       └── unified_dispatch.hpp
    │               ├── hardware_detect.hpp
    │               └── entropy.hpp
    ├── handrail.hpp
    │       └── types.hpp
    ├── stream_ingest.hpp
    │       └── types.hpp
    └── types.hpp
            └── config.hpp (generated)
```

No circular dependencies. Each module can be used independently.

## Data Flow per Token

1. **Ingestion** — Raw logits/probs/logprobs arrive via JSONL, socket, or shared memory
2. **Kernel dispatch** — `UnifiedDispatch::best_backend()` selects the optimal backend based on:
   - User override (if set)
   - Hardware capabilities (CUDA > Metal > AVX-512 > AVX2 > SSE4.2/NEON > OpenMP > Scalar)
   - Kernel type (SSE4.2/NEON only support `configurational_entropy`)
3. **Entropy computation** — Returns H in bits via log-sum-exp, probs, or logprobs formula
4. **Window update** — Circular buffer updated with new H value
5. **Statistics** — Two-pass mean and population variance over the window
6. **Collapse check** — `δ = H_current - mean`, `z = δ / σ`, collapsed if `δ < threshold`
7. **Handrail** — If collapsed, evaluate escalation state machine (first vs. sustained, cooldown)

## Thread Safety Model

| Component | Thread-safe? | Mechanism |
|-----------|-------------|-----------|
| `UnifiedDispatch::detect()` | Yes | `std::call_once` |
| `UnifiedDispatch::override_` | Yes | `std::atomic<Backend>` |
| `UnifiedDispatch::compute_*` | Yes | Read-only after `detect()` |
| `HandrailEngine::evaluate()` | Partially | Counters are `atomic<int>`, `last_action_time_` guarded by `mutex` |
| `CollapseDetector` | No | Single-threaded by design (document) |
| `TerminalAgent` | No | Single-threaded ingestion loop |
| `HardwareCapabilities` | Yes | Meyers singleton, immutable after construction |
| `entropy kernels` | Yes | Pure functions, no mutable state |

### HandrailEngine concurrency detail

`evaluate()` can be called from a monitoring thread while `total_collapses()` is read from a stats thread. The counters use `std::atomic<int>` with `memory_order_relaxed`. The `last_action_time_` field is protected by `std::mutex` in both `cooldown_ok()` and `execute_action()`. The webhook `fork()`+`execvp()` path uses `std::atomic<bool>` for the SIGCHLD handler installation guard.

## Hardware Detection Pipeline

```
detect_hardware()
    ├── detect_x86_simd()
    │       ├── CPUID leaf 1: SSE4.2, FMA, OSXSAVE
    │       ├── CPUID leaf 7: AVX2, AVX-512F/DQ/BW/VNNI
    │       └── XCR0 check: YMM/ZMM state enabled by OS
    ├── detect_arm_neon()     ← compile-time on aarch64
    ├── detect_openmp()       ← omp_get_max_threads()
    ├── detect_eigen()        ← compile-time flag
    ├── detect_cuda()         ← cudaGetDeviceCount() + cudaGetDeviceProperties()
    ├── detect_rocm()         ← hipGetDeviceCount() + hipGetDeviceProperties()
    └── detect_metal()        ← compile-time on Apple (runtime probe is TODO)
```

All results cached in a Meyers singleton. Second call is O(1).

## Build Architecture

Each SIMD kernel lives in its own translation unit with targeted ISA flags:

```
entropy_scalar.cpp    → baseline ISA (no special flags)
entropy_omp.cpp       → baseline ISA + OpenMP linkage
entropy_sse42.cpp     → -msse4.2
entropy_avx2.cpp      → -mavx2 -mfma
entropy_avx512.cpp    → -mavx512f -mavx512dq -mavx512bw -mfma
entropy_neon.cpp      → baseline ISA on aarch64 (NEON is always available)
entropy_gpu.cu        → NVCC (CUDA architectures 70-90)
entropy_metal.metal   → xcrun metal → .metallib
```

All other source files (`handrail.cpp`, `collapse_detector.cpp`, etc.) compile at baseline ISA. This ensures no SIGILL on lesser CPUs — only the dispatch-selected kernel is ever called.

## Stream Ingestion Modes

### Stdin JSONL

```
{"logits": [0.1, 2.3, -1.5, ...]}
{"logits": [0.2, 1.8, -0.9, ...]}
```

Line-by-line parsing. `strtod` operates on a null-terminated `std::string` copy for safety.

### Unix Domain Socket

```
connect() → listen() → read JSONL frames → callback per frame
```

Low-latency local IPC. `stop()` calls `shutdown(fd)` to break the read loop.

### Shared Memory (zero-copy)

```
Layout: [std::size_t count][double data[count]]

Producer (LLM): writes logits directly into mapped region
Consumer (Shannon): polls via usleep, reads span{data, count}
```

Producer reset detection: if `count < last_seen_index_`, the index resets to 0.

## Escalation State Machine

```
evaluate(collapsed_result):
    if not collapsed:
        consecutive = 0
        return

    total++
    consecutive++

    if consecutive == 1:
        execute(on_first_collapse)
    else if consecutive >= sustained_threshold:
        execute(on_sustained_collapse)

execute(action):
    if action != LOG_ONLY and not cooldown_ok():
        return     ← suppress (too soon after last action)
    perform(action)
    if action != LOG_ONLY:
        update last_action_time_
```

The `else if` ensures that when `sustained_threshold == 1`, only the first-collapse action fires (not both).
