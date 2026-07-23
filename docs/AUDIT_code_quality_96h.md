# Shannon Code-Quality Audit (core + last ~96h companion surface)

**Auditor:** independent code-quality pass (read-only)  
**Scope:** Shannon entropy pipeline (C++/Python), data structures/algorithms, security hazards, companion apps (Pill, hub, iOS/iPad, ShannonCore pets/sync)  
**Out of scope:** FlexAID∆S docking science / CF.com  
**Method:** source inspection of algorithms and call sites; not commit-message archaeology alone  
**Date context:** HEAD on main; companion surface present as monorepo packages under `Pill/`, `hub/`, `agent_hub/`, `iOS/`, `iPad/`, `Packages/`, `watchOS/`

---

## Summary

Shannon’s **scalar log-sum-exp entropy kernel and C++ v2 collapse detector** are carefully written: Welford variance, bounded trace, backend fallthrough, and a solid GoogleTest suite for collapse/expansion/oscillation. The **Python public detector and streaming integrations are not at the same quality bar**—they still use the numerically weaker variance formula, carry a broken `collapse_score` expression, leave the documented C++ detector path dead (`_shannon_cpp`), and ship provider integrations that treat `CollapseResult` as a float and call a non-existent `_push_and_check`. Companion code (Pill bridge, SecureStore, CloudKit private-only sync) shows real security intent, but the **agent hub HTTP/socket path is effectively unauthenticated** and has a **hard schema bug** that will throw on every `benchmark_update`.

**Overall grade: B−** for C++ core kernels/detector; **C** for the full monorepo as a product (Python API + hub + integrations pull the grade down).

---

## Core algorithms & data structures

### Configurational entropy (log-sum-exp)

Canonical form in C++ scalar (`src/shannon/entropy_scalar.cpp:22-49`) and v1 (`src/shannon.cpp:28-58`):

\[
\max_w = \max_i w_i,\quad
Z = \sum_i e^{w_i-\max_w},\quad
H = \log_2 Z - \frac{1}{Z\ln 2}\sum_i (w_i-\max_w)\,e^{w_i-\max_w}
\]

- Empty / singleton → `0.0` (correct convention for a degenerate support).
- Clamps with `std::fmax(0.0, …)` (NaN-safer than `std::max` for floating types).
- Python NumPy path (`python/shannon/_numba_fallback.py:55-75`) uses the algebraically equivalent form  
  \(H = \log_2 e \cdot (\log Z_{\text{nats}} - \mathbb{E}[x])\) — good.
- Numba path uses `prange` **without** `parallel=True` on `@njit` — the reduction is still serial; not wrong, just dead parallel intent (`_numba_fallback.py:123-126, 166-170`).

### Entropy from probabilities / logprobs

- Probs: standard \(H=-\sum p\log_2 p\) with `kEpsilon = 1e-300` floor.
- Logprobs: assumes natural log; converts via `kLog2E`. Debug-only normalization assert (`entropy_scalar.cpp:73-77`) — release builds will silently compute garbage on unnormalized inputs (documented risk, not a crash).
- **Top-k truncation hazard (API-level):** OpenAI/xAI integrations feed only `top_logprobs` (≤20). That is *not* a full distribution; \(H\) is systematically **underestimated** (missing mass ignored). Fine as a relative signal if documented; dangerous if treated as absolute bits.

### Sliding-window collapse detector

**C++ v2** (`src/shannon/collapse_detector.cpp`):

| Structure | Role | Complexity |
|-----------|------|------------|
| `std::vector<double> window_` | Circular buffer, `window_pos_ % window_size_` | O(1) write |
| Welford online mean/M2 | Recomputed over window each step | O(W), W default 8 |
| `std::deque<double> trace_` | Entropy history, hard cap 10_000 | O(1) push/pop |
| `std::vector<EntropyEvent> event_history_` | Oscillation ring | O(W_osc) scan |

Classification uses **absolute delta in bits** (`delta < collapse_threshold`), **not** z-score, despite docs/marketing emphasizing z-score (`collapse_detector.cpp:80-85`, `129`). Z is computed and exported but does not gate the event. That is intentional and consistent with tests, but the public narrative oversells “z-score threshold δ < −3.2”.

**Self-inclusion bias:** current \(h\) is written into the window *before* mean/std are computed (`107-125`). For window size \(W\), a pure step of size \(D\) yields \(|\delta|\approx D\cdot(W-1)/W\). With \(W=8\), sensitivity is reduced ~12.5%. Tests encode this (e.g. mean after inject includes the new point: `tests/cpp/test_shannon_v2.cpp:644-647`).

**C++ v1** (`src/shannon.cpp:141-191`): same circular buffer but **unbounded `trace_`**, running-sum variance \(E[X^2]-E[X]^2\) (numerically fragile when \(H\) is nearly constant), no expansion/oscillation. Still what `bindings.cpp` / `shannon_core` expose to Python.

**Python detector** (`python/shannon/detector.py:397-480`):

- `deque(maxlen=W)` + running sum/sum-sq — O(1) window update.
- Variance is **population** (\( / n \)), not sample (\( / n-1 \)) as in C++ v2 Welford — Python vs C++ disagree on `window_std` / z-score for the same series.
- `_trace: list[float]` is **unbounded** (no MAX_TRACE) on the pure-Python path.

### Unified dispatch

`UnifiedDispatch` (`src/shannon/unified_dispatch.cpp`): Meyers singleton, `std::call_once` detect, atomic backend override, GPU claimed only when compile flags set, NEON vs OpenMP size threshold (`n ≥ 16384`). Fallthrough with `[[fallthrough]]` and `ran` flag correctly rewrites `used_backend` to the kernel that actually ran. Solid.

### Mutual information (claimed)

`src/shannon/mutual_info.{hpp,cpp}`:

- **Not linked** into `shannon_v2` (`CMakeLists.txt` `SHANNON_V2_BASE_SOURCES` omits `mutual_info.cpp`). Dead code relative to the build.
- `result.mi_bits = result.kl_forward` (`mutual_info.cpp:210`) — this is **KL(p_t+1 ‖ p_t)**, not mutual information \(I(X_t;X_{t+1})\). Naming is misleading.
- JS formula at `207` is non-standard and not equal to \(JS = \tfrac12 KL(p\|m)+\tfrac12 KL(q\|m)\); the dedicated `js_divergence_scalar` is correct, but the tracker ignores it.
- Trace growth: `max_trace_size_ == 0` by default → **unbounded** `std::vector` growth; when capped, uses `erase` at front of vector (O(n)), unlike detector’s deque.
- When vocab sizes differ, `dim = min(|prev|, n)` silently truncates alignment — wrong if index spaces are full vocabularies that grew.

### Stream ingest

- Minimal JSON array parser is fine for numeric arrays; nested arrays / strings break (`stream_ingest.cpp:24-48`).
- `extract_field` finds first `"field"` substring match — can hit the wrong key if names overlap (e.g. nested or similarly named keys).
- `SocketIngester::listen` does **not** increment a token index on the local `parser` path and never calls handrail path differences vs stdin (format hard-coded to logits).
- `ShmemIngester`: maps `sizeof(size_t) + max_tokens * 8` with default `max_tokens=128000` (~1 MiB). **No memory ordering / sequence counter** between producer and consumer — torn reads of `count` or partial doubles are possible. Treat as prototype IPC only.
- `leftover` string on socket path can grow if peer never sends `\n` (mitigated in Python pill bridge with an 8 KiB limit; C++ socket path has **no** leftover size cap).

### Handrail

Escalation + cooldown design is coherent (`handrail.cpp`). Webhook uses `fork`+`execvp("curl", …)` without shell — good against injection. Remaining risks: arbitrary URL from config (SSRF if config is attacker-controlled), SIGCHLD globally set to `SIG_IGN` once, `kill`/`SIGABRT` against configured PID.

### Dual library / dual type systems

| Layer | Library | Detector type | CollapseResult |
|-------|---------|---------------|----------------|
| v1 | `shannon_core` (`shannon.cpp`) | `shannon::CollapseDetector` in `shannon.hpp` | no expand/oscillate |
| v2 | `shannon_v2` | `shannon::CollapseDetector` in `collapse_detector.hpp` | full events |
| Python | pure / `_core` | `ShannonCollapseDetector` | string `event` |

Same class name, different shapes — easy ODR/header confusion for any consumer that includes both trees. Python bindings link **only** `shannon_core` (`CMakeLists.txt:198-199`), so v2 detector/handrail/dispatch never reach Python.

---

## Issues

### bug — Python streaming integrations treat `CollapseResult` as `float` and call missing API

**Files:**  
- `python/shannon/integrations/openai_stream.py:101-108`  
- `python/shannon/integrations/xai_stream.py:103-110`  
- `python/shannon/integrations/perplexity_stream.py:110-117`  
- `python/shannon/integrations/vllm_local.py:87-103` (and async path ~148)

```python
H = detector.add_logprobs(lps)   # returns CollapseResult
...
entropy=H,                      # type: should be float
```

and fallback:

```python
detector._push_and_check(H)     # method does not exist on ShannonCollapseDetector
```

**Impact:** Runtime `AttributeError` / `TypeError` on real streams; CLI `cmd_openai` depends on this path (`cli.py:199-211`).  
**Suggestion:**  
```python
result = detector.add_logprobs(lps)
...
entropy=result.entropy
...
# missing top_logprobs:
result = detector._push(0.0)  # or push_entropy equivalent
```

### bug — `collapse_score` operator-precedence error

**File:** `python/shannon/detector.py:349-353`

```python
return abs(self._trace[-1] - self._current_mean / max(1, len(self._window)) / abs(self._threshold))
```

Evaluates as  
\(|H - \frac{\mathrm{mean}}{W\cdot|\theta|}|\), not \(|H-\mathrm{mean}|/|\theta|\).  
Docstring claims “`|delta / threshold|`, >1.0 means collapsed.” Event path at line 471 uses the correct form.  
**Suggestion:**  
`return abs(self._trace[-1] - self._current_mean) / abs(self._threshold)`.

### bug — Hub `benchmark_state` INSERT columns ≠ CREATE TABLE

**File:** `hub/shannon_gate.py`

- Schema: `progress`, `state_json` (`291-297`)  
- Writer: `completed, total, best_cf, best_rmsd, active_target, state_json` (`474-491`)

Any `message_type == "benchmark_update"` → SQLite operational error. Tests never exercise `update_benchmark_state`.  
**Suggestion:** Align INSERT with schema (pack domain fields into `state_json`, set `progress=state.get("completed",0)`), or migrate schema deliberately and test.

### bug — Python C++ detector fast path is dead / desynced

**File:** `python/shannon/detector.py:241-252`

```python
from _shannon_cpp import CollapseDetector as CppDetector
```

Module was renamed to `shannon._core` (CHANGELOG); `_core` exposes `SlidingWindowEntropy`, not v2 `CollapseDetector`. Import always fails → pure Python path only. Properties `is_collapsed`, `collapse_score`, `current_entropy`, `delta_h` still read **Python-only** `_trace` / `_event_history` / `_window` (`341-346`, `349-353`, `356-358`, `361-380`). Even if import were fixed without also mirroring state into Python fields, those properties would stay wrong.

### high — Agent hub authentication is documentation-only

**Files:** `hub/shannon_gate.py:119-122, 728-765, 956-1076`

- `HUB_SECRET` is generated and never checked on Unix registration or HTTP `POST /message`.
- HTTP allows any `agent_id ∈ VALID_AGENTS` with no API key / Bearer check.
- Unix socket mode `0o660` (`1098`) — group-readable, not owner-only.
- Comments claim socket secret handshake; code does not implement it.

**Impact:** Any local process (or LAN peer if bound `0.0.0.0`) can inject messages, poison audit log, and broadcast to connected agents.  
**Suggestion:** Require `Authorization` / shared secret on HTTP; require secret field on first Unix frame; chmod `0o600`; fail closed.

### high — Dual `hub/` vs `agent_hub/` + divergent SQLite schemas

`hub/tools/dataset_runner_bridge.py:77-83` creates `benchmark_state(agent_id PRIMARY KEY, progress, state_json, …)` while `shannon_gate.AuditDB` uses a different shape. Bridge tests query `agent_id` columns the gate schema does not have. **Two hubs, two schemas, one monorepo** — high risk of wiring the wrong tree in deployment.

### high — MI module advertised but not built; “MI” is KL

- Not in CMake sources → cannot be tested or linked.  
- Semantic error: KL ≠ MI (`mutual_info.cpp:210`).  
README claims production MI tracking (`README.md` ~961+).  
**Suggestion:** Either wire into `shannon_v2` + tests with correct \(I(X;Y)=H(X)+H(Y)-H(X,Y)\) (or a clearly named `kl_to_previous`), or delete/relabel.

### medium — Variance formula / sample vs population inconsistency

| Implementation | Variance |
|----------------|----------|
| C++ v2 Welford | sample, `/(n-1)` (`collapse_detector.cpp:122`) |
| C++ v1 running | population, `/n` (`shannon.cpp:166-168`) |
| Python detector | population, `/n` (`detector.py:415-416`) |
| MutualInfoTracker | population, `/n` (`mutual_info.cpp:172-174`) |

Affects z-score magnitude and any threshold logic that might later switch to z.  
**Suggestion:** One definition (prefer Welford sample, or document population everywhere).

### medium — Classification is delta-bits, not z-score

`classify_event` uses raw delta (`collapse_detector.cpp:80-85`). Docs (`docs/theory.md`, package summary) emphasize z-score δ < −3.2. With constant window, `window_std→0` and z is forced to 0 (`126`) while collapse can still fire on delta — **correct for delta thresholds**, confusing for z-based ops. Rename thresholds in docs/API or switch detector if z is the real product claim.

### medium — Python pure path unbounded memory

`detector.py:234,399` `_trace.append` with no cap; long-running `shannon-monitor` can grow without bound. C++ v2 caps at 10k.  
**Suggestion:** mirror `max_trace_size` with `deque(maxlen=…)`.

### medium — Handrail default actions can SIGTERM / SIGABRT monitored PID

Defaults in `types.hpp:117-118`: first collapse → `ALERT` (SIGUSR1), sustained → `KILL` (SIGTERM). Safe only if config is explicit; a mis-set `monitored_pid` is destructive. Tests cover LOG_ONLY paths well; production CLI defaults need loud warnings.

### medium — Shared-memory / socket ingest lack DoS bounds (C++)

`stream_ingest.cpp:164,215` append to `leftover` with no max size. Malicious peer can force large allocations. Python pill bridge limits to 8192 (`pill_bridge.py:197-205`) — good pattern to port.

### medium — Top-k logprobs entropy bias in all cloud integrations

Only top-20 logprobs → incomplete support; \(H\) not comparable to full-vocab logits. Document or renormalize missing mass (e.g. assume residual uniform / ignore and mark `partial=True`).

### low — Null pointer / empty not fully guarded on all kernels

`configurational_entropy_scalar(nullptr, n>0)` is UB. Dispatch does not validate pointers. Callers from bindings always copy into vectors (safe); raw C++ API is sharp.

### low — `SocketIngester::listen` hardcodes field `"logits"`

Ignores configured input format for socket mode (`stream_ingest.cpp:156`); TerminalAgent socket path always `add_logits` (`terminal_agent.cpp:137`).

### low — JSON field extraction false positives

`extract_field` (`stream_ingest.cpp:51-80`) first `"name"` match; no structural JSON parse. Prefer a real parser or stricter tokenization.

### low — TurboQuant Lloyd-Max is O(iters · n · levels) with empty-bin stagnation

`turbo_quant.cpp:45-70`: empty centroids never move; 5 iters fixed. Acceptable for prototype quant monitoring, not production adaptive codebooks.

### low — `_PyFastOPTICS` is k-means, not OPTICS

`detector.py:103-167`: O(n·k) k-means++ with silent `except Exception: pass` on clustering (`534-535`). Name overclaims algorithm.

### nit — Duplicate / legacy packages

- `tests/test_detector.py` vs `tests/python/test_detector.py`  
- `agent_hub/` vs `hub/`  
- `shannon.cpp` v1 vs `src/shannon/*` v2  
Keep one canonical tree.

### nit — License header mismatch

Some files MIT SPDX (`shannon.cpp`), package Apache-2.0 (`pyproject.toml`). Cosmetic but audit-relevant for redistribution.

---

## Last-96h companion app additions

*(Companion surface as present in-tree; CHANGELOG 2.0.0 dated 2026-07-16 plus monorepo apps. Assessment is of **shipped source quality**, not individual commit SHAs.)*

### Pill (`Pill/`, `python/shannon/pill_bridge.py`)

**Strengths**

- Clear consumer-only RPC: `status` command only (`pill_bridge.py:191-194`) — good attack-surface reduction.
- Socket `0o600`, path length guard, stale socket unlink, line size limit — solid local IPC.
- Tests cover permissions, malformed JSON, unknown commands (`tests/python/test_pill_bridge.py`).
- Swift client (`Pill/Sources/PillCore/ShannonBridge.swift`) mirrors codec; `nonisolated` default path; missing socket → disconnected, not crash.

**Issues**

- Demo detector ticks entropy on every property read (`pill_bridge.py:215-231`) so a single `status_payload` advances the counter multiple times — UI flicker / desync in `--demo` only.
- Bridge does not use the v2 C++ agent; it only mirrors Python detector state (depends on Python correctness above).

### Hub / Agent Hub (`hub/`, `agent_hub/`)

**Strengths**

- Gate entropy on **message text** is a deliberate, separate product (not token-logit Shannon); unit tests for token/structural entropy are clear (`hub/tests/test_shannon_gate.py`).
- Credentials via Keychain (`credentials.py`, `SecureStore.swift`) — no secrets in SQLite by design.
- Audit DB WAL + auth event tables (metadata only).

**Issues (critical for production)**

1. Unauthenticated HTTP / unused `HUB_SECRET` (above).  
2. `update_benchmark_state` schema bug (above).  
3. Duplicate trees `hub/` and `agent_hub/` invite drift.  
4. Gate “Shannon” is **whitespace token entropy of agent prose**, unrelated to `shannon_configurational_entropy` — naming collision will confuse operators and false-security claims.  
5. Soft-pass on network failure in `check_cloud_agent` (`credentials.py:269-275`) can green-light missing auth in CI-like environments.

### ShannonCore / multi-device (`Packages/ShannonCore`)

**Strengths**

- Explicit private CloudKit zone only (`ShannonSync.swift` comments + API).  
- `SecureStore` uses Keychain, `afterFirstUnlock`, access group documented; no secret fields on sync models.  
- InMemory backend for tests; decode skips malformed records.  
- Pet / confirmation / pencil models are structured and tested (`Packages/ShannonCore/Tests/`).

**Issues**

- Large surface (pets, now playing, pencil, voice, docking progress) relative to core entropy library — monorepo cohesion risk: regressions in “phone pet UX” unrelated to safety primitive.  
- CloudKit conflict policy “higher level wins” for pets may drop concurrent XP updates (product choice; document).

### iOS / iPad / watchOS

- Thin UI shells over ShannonCore; iPad hub views are substantial (`iPad/Sources/ShannonPad/Views/*`).  
- No evidence in this audit of direct entropy math on device — correct layering if Mac/Python remains source of truth.  
- Ensure entitlements/keychain groups stay aligned with `SecureStore.accessGroup` (documented in `docs/MULTI_DEVICE.md`; not re-verified line-by-line here).

### Overall companion grade

| Component | Grade | Notes |
|-----------|-------|-------|
| Pill bridge | **A−** | Best local security story; tested |
| ShannonCore secrets/sync | **B+** | Thoughtful boundaries |
| Hub gate math | **B** | Internally consistent, wrong name vs core |
| Hub auth + DB write path | **D** | Secret unused; schema break |
| Streaming integrations | **D** | Broken against current detector API |

---

## Test/coverage gaps

### Well covered

- Scalar entropy identities, cross-check config vs probs (`tests/cpp/test_shannon_v2.cpp`)  
- Collapse / expansion / oscillation / handrail LOG paths  
- Python configurational entropy + basic detector + synthetic FP rate  
- Pill socket round-trip and mode bits  
- Hub analyzer unit tests (token entropy, disagreement)

### Missing or weak

| Gap | Why it matters |
|-----|----------------|
| No tests for `openai_stream` / `xai_stream` / `vllm_local` / `perplexity_stream` | Broken today; would fail immediately |
| No test for `collapse_score` numerical value | Precedence bug undetected |
| No MI / KL / JS unit tests | Module unbuilt; formula wrong |
| No `update_benchmark_state` test | Schema bug undetected |
| No HTTP auth / secret handshake tests | Security regression free pass |
| No Python↔C++ parity tests for same logit series (H, mean, std, event) | v1/v2/Python drift |
| No SIMD vs scalar bit-identical / rtol suite on random vocab | NEON/AVX path confidence |
| No fuzz/property tests for JSONL ingest | leftover growth, bad JSON |
| No integration test that handrail fires from TerminalAgent stream | callback wiring only lightly covered |
| `is_collapsed` with C++ path | would fail if import fixed without state sync |
| Hub vs bridge schema contract test | divergent SQLite |

---

## Recommendations (prioritized)

### P0 — fix before relying on integrations or hub writes

1. **Repair streaming integrations** to use `CollapseResult.entropy` and `_push` (or public `push_entropy`); add pytest with mocked client chunks.  
2. **Fix `collapse_score` parentheses** and assert `score == abs(delta)/abs(threshold)`.  
3. **Fix `AuditDB.update_benchmark_state`** to match CREATE TABLE; add regression test.  
4. **Implement or remove hub auth** (`HUB_SECRET` on Unix; API key on HTTP); chmod socket `0o600`.

### P1 — core product honesty & parity

5. **Single detector story for Python:** bind v2 `CollapseDetector` via pybind11 *or* delete dead `_shannon_cpp` import; sync `is_collapsed` / trace / window to one backend.  
6. **Unify variance** (Welford sample everywhere) and **document delta-vs-z** thresholds.  
7. **Either build MI properly** (correct definition + CMake + tests) **or stop advertising it**.  
8. Cap Python `_trace`; port leftover size limits to C++ socket ingest.

### P2 — architecture hygiene

9. Collapse `hub/` and `agent_hub/` to one package; one SQLite schema; bridge and gate share models.  
10. Deprecate/archive v1 `shannon.cpp` detector once Python uses v2; avoid two `CollapseResult` types.  
11. Add SIMD-vs-scalar parity tests and pointer null checks on public C++ kernels.  
12. Rename hub “Shannon gate” metrics (`gate_H` text entropy) to avoid collision with token-distribution entropy.

### P3 — hardening

13. Sequence counters / atomics for shmem protocol.  
14. Explicit residual-mass policy for top-k logprobs.  
15. Handrail defaults: refuse KILL without `--i-know` or require explicit action flags.  
16. CI job: `pytest tests/python` + hub tests + `ctest` on every PR (confirm companion packages are not untested orphans).

---

## Appendix: key file map

| Concern | Path |
|---------|------|
| Scalar kernel | `/Users/lp.more/Projects/Shannon/src/shannon/entropy_scalar.cpp` |
| v2 detector | `/Users/lp.more/Projects/Shannon/src/shannon/collapse_detector.cpp` |
| Dispatch | `/Users/lp.more/Projects/Shannon/src/shannon/unified_dispatch.cpp` |
| MI (unbuilt) | `/Users/lp.more/Projects/Shannon/src/shannon/mutual_info.cpp` |
| Ingest | `/Users/lp.more/Projects/Shannon/src/shannon/stream_ingest.cpp` |
| Handrail | `/Users/lp.more/Projects/Shannon/src/shannon/handrail.cpp` |
| Python detector | `/Users/lp.more/Projects/Shannon/python/shannon/detector.py` |
| Backends | `/Users/lp.more/Projects/Shannon/python/shannon/_numba_fallback.py` |
| Integrations | `/Users/lp.more/Projects/Shannon/python/shannon/integrations/*.py` |
| Pill bridge | `/Users/lp.more/Projects/Shannon/python/shannon/pill_bridge.py` |
| Hub gate | `/Users/lp.more/Projects/Shannon/hub/shannon_gate.py` |
| Bindings (v1 only) | `/Users/lp.more/Projects/Shannon/src/bindings.cpp` |
| CMake | `/Users/lp.more/Projects/Shannon/CMakeLists.txt` |

---

*End of audit. No source was modified except this report file.*
