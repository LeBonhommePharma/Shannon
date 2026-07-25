# Shannon ↔ AgentPeek — Reconnaissance & Gap Analysis

**Date:** 2026-07-25
**Scope:** `~/Projects/Shannon` (`Pill/` target), compared against AgentPeek 0.2.69
**Status of this document:** plan only. No implementation code was written.

---

## 0. Verdict up front

**The hypothesis holds.** Shannon's `Pill/` target *is* a native macOS notch +
menu-bar app for monitoring coding agents. It is not a repurposed analogy — it
is a direct category peer of AgentPeek, built independently.

But there is one architectural difference that dominates every row of the gap
table below, and it needs to be stated before anything else:

| | AgentPeek | Shannon |
|---|---|---|
| **Telemetry model** | **Pull.** Reads artifacts the agent already writes to disk (`~/.claude/projects/*.jsonl`, `~/.codex/sessions`, `~/.copilot/session-store.db`, `~/.cline/data/db/sessions.db`, …) and installs vendor-supported hooks. | **Push.** An agent is only "live" if its process registered with `hub/shannon_gate.py` over `/tmp/shannon.sock` and speaks Shannon's own protocol. |
| **Fallback when the agent doesn't cooperate** | Still sees the session — the transcript is on disk regardless. | Sees nothing but a *frontmost-app observation* captured manually with ⌘D, which `GateDBReader.swift` itself correctly annotates as "useful as a label, worthless as proof that an agent is working." |

Shannon's own source comment is the honest summary:

> `GateDBReader.swift:32` — *"This is the **only** source of real agent telemetry
> the pill has: a row in `agents` means a process actually spoke to the gate over
> `/tmp/shannon.sock`. Everything else the pill knows (pets, `agents.json`) is
> derived from which macOS app happened to be frontmost when the user pressed ⌘D."*

**Consequence:** Shannon cannot currently observe a Claude Code session it did
not launch through its own hub, and it has **no token/cost/quota tracking of any
kind**. `grep -rn "token" Pill/Sources/` returns only Shannon-entropy token
counts and unrelated design tokens — not a single LLM billing token.

Everything else in this document follows from that one gap.

---

## 1. Where Shannon lives

| | |
|---|---|
| **Local path** | `~/Projects/Shannon` |
| **macOS app** | `~/Projects/Shannon/Pill` (SwiftPM package `ShannonPill`) |
| **Remote** | `https://github.com/LeBonhommePharma/Shannon` (public) |
| **Branch** | `main` @ `993eef0` *feat(pill): recognize Claude Design as its own agent* |
| **Other branches** | `audit/entropy-2026-07-23`, `claude/shannon-entropy-library-epXQ2`, `repaired-history`, 2 `Bonhomme/*` |

Searched and ruled out: `~/Developer` and `~/Code` do not exist. `~/Documents`
holds no Swift project. The `swift/` directory referenced in the brief is
`~/Projects/FlexAIDdS/swift`, which is a *different* concern (FlexAIDdS
bindings), not Shannon.

`gh` is authenticated as **LeBonhommePharma**. There is no GitHub user or org
named `lmorency` — `gh repo list lmorency` returns *"the owner handle
'lmorency' was not recognized."* `NRGlab` exists (23 repos) but contains **no**
Shannon repo; it is entirely docking/bioinformatics (FlexAIDdS, NRGRank,
Surfaces, ENCoM, …). Shannon lives only under `LeBonhommePharma`.

`~/.claude/skills/shannon/` is indeed empty — it is a stub, not a source of truth.

### Repo shape

Shannon is **two projects in one repo**:

1. **A Shannon-entropy C++/Python library** — `src/shannon.cpp`, `CMakeLists.txt`,
   `pyproject.toml`, `hub/behavioral_entropy.py`, benchmarks, iOS/iPad/watchOS
   companions. This is the FlexAIDdS-adjacent research code.
2. **`Pill/` — the macOS notch app.** This is the AgentPeek peer, and the only
   part this document analyses.

They are coupled through `~/.shannon/pill.sock` (entropy readout) and
`~/.shannon/agent_hub.db` (agent telemetry).

---

## 2. Shannon `Pill/` inventory — what actually works

**Build verified:** `cd Pill && swift build` → **`Build complete! (11.82 secs.)`**, exit 0.
No warnings surfaced in the tail. This is a healthy, compiling codebase.

| | |
|---|---|
| **Toolchain** | `swift-tools-version:5.9`; builds under the Xcode 27 / Swift 6.4 toolchain on this machine |
| **Deployment target** | **macOS 13 (Ventura)** — *lower than AgentPeek's macOS 14* |
| **Architecture** | 4 SwiftPM packages: `ShannonPill` (executable, 11 files) → `PillCore` (library, 37 files) → local `Packages/ShannonCore` (22 files) + `Packages/ShannonTheme` |
| **Source size** | ~30,600 lines of Swift across `Pill/` |
| **Tests** | 2 test targets, **48 test files** (`PillCoreTests` + `ShannonPillTests`). Genuinely disciplined: pure logic is extracted behind protocols with deterministic stubs so tests run with no window server, no media session, no live agent. |
| **Sandbox** | **Off** (required for IOKit + MediaRemote). Hardened Runtime on. Cannot ship on MAS — same distribution constraint AgentPeek has. |
| **Bundle** | `com.lebonhommepharma.shannon.pill`, `LSUIElement` agent app, v0.1.0 |
| **Distribution** | Homebrew Cask/Formula + `fastlane/` present; DMG/notarization path partially built |

### Honest feature ledger

**Works, verified:**

- **Notch geometry** — `NotchGeometry.swift` derives the notch rect from
  `NSScreen.safeAreaInsets.top` + `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`,
  synthesising an equivalent rect on notchless/external displays. **All public
  API.** Non-activating `.borderless` panel above `CGWindowLevelForKey(.statusWindow)`
  so it never steals focus. This is done correctly and is a genuine asset.
- **Menu bar status item** — always present, independent of the notch, with a
  popover (`MenuBarPopoverView.swift`, 1214 lines) containing header, benchmark
  surface, keep-awake, system resources, agents, abandoned approvals, recent
  activity, entropy readout, footer.
- **Gate approval flow** — `GateDBReader` (read) + `GateApprovalClient` (write over
  `/tmp/shannon.sock`) surface **pending asks with allow/deny**, plus explicit
  `staleAsks` handling so the menu bar stops pulsing amber forever. Notably, it
  distinguishes `presence: .live / .offline / .observed` so foreground guesses
  cannot masquerade as telemetry. **This is architecturally better than a naive
  implementation and is the seed for real permission handling.**
- **Terminal process probing** — `TerminalAgentProbe.swift` (642 lines) walks the
  terminal's process descendants (through tmux/screen/ssh multiplexers), strips
  version stamps (`grok-0.2.111` → `grok`), resolves `node …/cli.js` launches via
  path markers, and classifies against a deliberate **whitelist** so `cd ~/claude-notes`
  cannot mint an agent. Real engineering.
- **⌘D frontmost capture** — `AgentIngest.swift` (1594 lines) + `HotkeyMonitor`.
  Resolves the frontmost app → agent, with an explicit `notAnAgent` refusal path
  (e.g. it deliberately refuses "Usage for Claude.app"). Creates a "pet" under
  `~/.shannon/pets/<id>/` with `memory.md`, `history.jsonl`, `config.json`, `state.json`.
- **System resources HUD** — CPU/GPU/RAM/SSD/temperature, iStat-style, with
  exponential smoothing and proportional scarcity tint (`SystemResources.swift`,
  1026 lines; `ResourceScarcityTint.swift`).
- **Native keep-awake** — `KeepAwake.swift` / `AmphetamineControl.swift`,
  caffeinate-class, no third-party app required.
- **Battery ring** — IOKit, edge-triggered alerts, re-arm hysteresis.
- **Entropy integrity** — `EntropyIntegrity`, `EntropyProvenance`, `GateEntropyClock`.
  This is Shannon's differentiator and it is rigorous: it **refuses** to display a
  score whose `entropy_updated_ns` is 0 rather than aging a frozen value off
  `last_seen`. Nothing in AgentPeek does this.
- **Notifications** — `ShannonNotifier.swift` via `UNUserNotificationCenter`,
  currently firing on entropy collapse and gate asks.
- **Settings window** — real, live-bound (`SettingsView.swift`, 5 sections:
  keep-awake, pill, agents, tips, data).
- **Pet companion** — `PetCompanion` + `PetCompanionArt` (1146 lines combined).
  Shannon-specific; no AgentPeek analogue.

**Built but hardware-unproven (per `BLOCKED.md`):**

- Head-gesture confirm (nod = allow, shake = deny) via `CMHeadphoneMotionManager`.
  27 unit tests on synthetic attitude streams, **zero runs against real AirPods**.
  macOS 14+ only; `NSMotionUsageDescription` TCC, **no entitlement needed**.
- Head-orientation browse — pure detector shipped, no UI consumer wired.
- Voice dictation — on-device `SFSpeechRecognizer`, 32 parser tests, **never run
  against a live microphone**. Hard-fails rather than falling back to servers.

**Blocked at the platform level (documented, correctly):**

- Now Playing for arbitrary apps — MediaRemote entitlement-gated since macOS 15.4;
  AppleScript fallback covers Music + Spotify only.
- Notification mirroring — no macOS API. Correctly deferred.
- AirDrop, AirPods battery, in-ear detection, stem presses — no third-party API.
- Focus/DND — best-effort `Assertions.json` parse, fails closed to `.unknown`.

**Agent coverage:** 8 IDs in the `TerminalAgentProbe` whitelist —
`claude_code`, `codex`, `grok_build`, `cowork`, `dispatch`, `chatgpt`,
plus Shannon-specific `science` and `design`. AgentPeek covers **25**.

---

## 3. AgentPeek feature matrix

All 16 requested pages plus `llms.txt` were fetched successfully. **None were
JS-rendered empty shells** — the site is server-rendered and `llms.txt` is a
dense, unusually honest machine-readable capability ledger. Sources are listed
at the end of this document.

AgentPeek's stated boundaries, which are worth adopting as design constraints:

> *"A visible session does not imply that AgentPeek can answer its permissions,
> resume it, reconstruct private reasoning, or infer a provider quota."*
> *"Missing data stays missing. AgentPeek does not manufacture it."*
> *"It never turns raw tokens, context size, credits, account balance, or
> estimated cost into a quota percentage."*

This is the same epistemic discipline `EntropyIntegrity.swift` already applies to
entropy. Shannon should extend that discipline to usage rather than invent a new one.

### Feature extraction

| # | Feature | Concrete behavior |
|---|---|---|
| F1 | **Notch pill (collapsed)** | Glanceable pill under camera housing; active-session count *or* usage gauges; modes: always-visible / hide-when-idle / expanded-only / usage-gauge |
| F2 | **Expanded notch panel** | Sessions, prompts, transcripts, servers, Chat, Quick Routes, Fast Actions, Views, Agent Board, usage, settings, updates, licensing |
| F3 | **Auto-expand on attention** | Panel opens itself when a proven attention event arrives (permission/question/completion) |
| F4 | **Global hotkey** | Toggle notch open/closed from anywhere; separate hotkeys to allow/deny the frontmost prompt without opening the app |
| F5 | **Menu bar mode** | Independent toggle from notch. Popover with usage gauges, Active + Metrics pages, one-click refresh. Works on notchless Macs / external displays |
| F6 | **Session monitoring** | Per session: agent, project, cwd, host terminal, state (executing/thinking/waiting/idle), elapsed, tokens, files, commands, diffs, last tool, prompt, reply, model, account, **git branch**, subagents, todos, recent events |
| F7 | **Session actions** | Inspect, copy Markdown, reveal paths, jump to owning terminal, refresh usage, dismiss quiet rows, end process after safety check |
| F8 | **Transcript reading** | Reads each agent's own on-disk session artifacts — JSONL, SQLite, rollout files — per-vendor |
| F9 | **Hook installation** | Managed per-agent installers that write an *owned, marked* block into `~/.claude/settings.json` etc., preserve unrelated user config, bounded timeouts, uninstall only own entries |
| F10 | **Permission answering** | Inline prompt with command / file path / diff. `⌘A` allow, `⌘N` deny, `⌥A` always-allow (only when the agent offers it), `⌥T` jump to terminal. Stacked prompts navigable by arrow keys |
| F11 | **Questions & plans** | Structured questions with choices, free-form input, multi-part (one card per part, single/multi-select, Send lights when complete), plan Approve/Reject, **reject-with-feedback** |
| F12 | **Direct Chat / follow-up prompts** | Composer continues a *selected persisted session* via agent-specific resume or ACP `loadSession`; validates session ID + cwd; streams reply; cancel in flight. Native window with session sidebar |
| F13 | **Provider quota windows** | Claude Code + Codex 5-hour and 7-day windows with reset/refill countdown; Cursor monthly |
| F14 | **Local token counters** | Per-agent monthly/daily token + cost totals read from local stores; explicitly *not* converted into quota percentages |
| F15 | **Usage visualization** | Battery-style gauges green→yellow→red; optional count-down mode; Metrics page with 14-day by-day chart + donut splitting input/output/cache-write/cache-read + per-model share; headline picks ≤4 agents |
| F16 | **Usage alerts** | Fire-once threshold 50–100% on 5h/7d/monthly/daily; limit reached, pace warnings, resets, account handoff; daily token budgets; daily/weekly/monthly spend caps; forecast budgets that can pause new prompts at 100% |
| F17 | **Dev server discovery** | Scans ports 3000–9999. Rows show port, framework (Next/Vite/Astro/Wrangler/Storybook/Playwright/static) or runtime (Node/Bun/Deno/Python/Ruby/Rust/Go), project folder from cwd, uptime |
| F18 | **Dev server actions** | Open URL, copy URL, copy port, jump to process context, stop process after safety check |
| F19 | **Quick Routes** | One-click Finder/editor opens for each agent's skills / agents / commands / rules / plugins / config / hooks / MCP / logs / sessions / DB / root. Missing routes shown **dimmed and disabled**, never created |
| F20 | **Fast Actions** | User-saved named shell commands. Run in a login shell from `$HOME`. Live status running/succeeded/failed, last line of output on failure, stoppable |
| F21 | **Views** | Named presets launching one terminal window as a workspace. Terminals: Terminal, Ghostty, iTerm, Warp, cmux, tmux. Layouts: side-by-side, stacked, 2×2, 2×3, 3×2, tabs, auto. Per pane: agent CLI or shell + cwd + optional command |
| F22 | **Floating widgets** | Tear-off (press-hold-drag or pop-out button): Todos, Active Usage, Transcript, Subagents, Tools. Float on any display, fold into rails, expand on hover, remember position **per project** |
| F23 | **Agent Board** | Floating kanban — Active / Attention / Finished, auto-sorted from live state, never manually filed. Movable, resizable, collapsible to a status pill |
| F24 | **Focus Inbox** | Ranks approvals, human decisions, failures, stale waits, quota pressure, runaway processes, finished work above the board |
| F25 | **Notifications** | Approval/question, turn >30s complete, subagent finished, unanswered-prompt reminder at 2 min, runaway-process alert (sustained high CPU/mem/disk-write). Per-event toggles |
| F26 | **Notification sound packs** | Separate banner/sound switches, one default event-sound pack, per-agent override, import folder of event-named AIFF/WAV/CAF, **quiet hours**, test button |
| F27 | **Parallel agent handling** | Prompt stacking across agents, attention flags, configurable visible row count |
| F28 | **Appearance / Size settings** | Pill visibility, glass opacity + depth, avatar colors, per-tool colors; expanded/collapsed widths, density, text size, session-list sizing, widget size |
| F29 | **Settings organization** | 12 tabs: General, Agents, Appearance, Size, Motion, Shortcuts, Advanced, Usage, Notifications, **Doctor**, License, About |
| F30 | **Sparkle updates** | Signed appcast, in-app update checks |
| F31 | **Agent breadth** | 25 agents with an explicit per-agent capability ledger stating exactly what is and is not supported |

---

## 4. Gap analysis

**Status key:** ✅ has · 🟡 partial · ❌ missing · 🚫 not worth building
**Difficulty:** S ≤ 2 days · M ≈ 1 week · L ≥ 2 weeks (single focused agent)

| # | Feature | AgentPeek behavior | Shannon status | Diff | Depends on |
|---|---|---|---|---|---|
| F1 | Collapsed notch pill | Glanceable; 4 display modes | ✅ **has** — `PillView.swift` collapsed section + `PillChromePolicy`. Missing only the usage-gauge mode | S (modes) | F14 for gauge mode |
| F2 | Expanded panel | 11 surfaces | 🟡 **partial** — has sessions, gate asks, entropy, resources, media. Missing servers / routes / actions / views / board / usage | — | W0 section registry |
| F3 | Auto-expand on attention | Opens on proven event | 🟡 **partial** — `expandPillOnLaunch` pref exists; `ConfirmationController` opens the question itself. No general attention-driven auto-expand | S | W0 |
| F4 | Global hotkey | Toggle + allow/deny frontmost | 🟡 **partial** — `HotkeyMonitor` (Carbon) exists for ⌘D capture. No toggle or answer hotkeys | S | F10 |
| F5 | Menu bar mode | Independent; usage gauges; Active/Metrics pages | 🟡 **partial** — menu bar is ✅ and already independent. No usage gauges, no Metrics page | M | F13/F14 |
| F6 | Session monitoring detail | 18+ fields incl. branch, model, diffs, todos, subagents | 🟡 **weak partial** — `AgentActivitySnapshot` has id, name, status, lastTask, source, presence, historyCount, heartbeat. **No** cwd, branch, model, tokens, files, commands, diffs, todos, subagents | **L** | **F8 (blocking)** |
| F7 | Session actions | 7 actions | 🟡 **partial** — dismiss + gate resolve exist. No copy-Markdown, reveal, jump-to-terminal, end-process | M | F6 |
| F8 | **Transcript / artifact reading** | Per-vendor JSONL + SQLite readers | ❌ **missing — the keystone gap.** `grep` for `.claude/projects`, `.jsonl`, `sessions.db`, `rollout`, `session-store` across `Pill/Sources/` returns only Shannon's *own* pet `history.jsonl`. Shannon reads no third-party agent artifacts at all | **L** | — (nothing; this unblocks everything) |
| F9 | Hook installation | Owned, marked, reversible config blocks | ❌ **missing** — zero matches for `settings.json`, `PreToolUse`, `PostToolUse`, `hooks` in `Pill/Sources/`. Shannon requires agents to speak its socket protocol instead | M | F8 |
| F10 | Permission answering | Inline diff/command + ⌘A/⌘N/⌥A/⌥T + stacking | 🟡 **real partial, best-in-class foundation** — `GateAskCard` + `GateInlineCard` + `GateApprovalClient` genuinely answer approvals, with stale-ask handling and token-superseding race protection. But **only for gate-registered agents**, no keyboard shortcuts, no diff rendering, no always-allow, no stacking | M | F8, F9 |
| F11 | Questions & plans | Multi-part, choices, free-form, reject-with-feedback | ❌ **missing** — `ConfirmationController` is binary confirm/deny only | M | F10 |
| F12 | Direct Chat / follow-up prompts | ACP `loadSession` or vendor resume; streaming; cancel | ❌ **missing.** Shannon's bridge is deliberately read-only: *"It answers `status` and nothing else — it is a readout, not an RPC surface"* (`Pill/README.md`) | **L** | F8; needs a deliberate reversal of the read-only bridge decision |
| F13 | Provider quota windows | Claude/Codex 5h + 7d with countdown | ❌ **missing** — no quota concept anywhere | M | F8 |
| F14 | Local token/cost counters | Monthly + daily per agent | ❌ **missing** — no LLM token accounting exists | M | F8 |
| F15 | Usage visualization | Gauges, 14-day chart, donut, per-model share | ❌ **missing** — but `SmoothLoadBar`, `SmoothCoreBar` and `SparklineView` already exist in `MenuBarPopoverView.swift` and are directly reusable | M | F13, F14 |
| F16 | Usage alerts & budgets | Fire-once thresholds, spend caps, pace, forecast-pause | ❌ **missing** | M | F13, F14, F25 |
| F17 | Dev server discovery | Ports 3000–9999, framework + project + uptime | ❌ **missing** — no `lsof`, no socket enumeration in `Pill/Sources/` | **S** | none — fully independent |
| F18 | Dev server actions | Open / copy / stop with safety check | ❌ **missing** — but `ProcessGuard.swift` already exists and is exactly the safety-check primitive needed | S | F17 |
| F19 | Quick Routes | Per-agent path catalog, dimmed when absent | ❌ **missing** — `NSWorkspace.shared.open` appears in only 2 files, for unrelated purposes | **S** | none — pure data + Finder calls |
| F20 | Fast Actions | Saved commands, login shell, live status | ❌ **missing** — but `Process()` spawning is already used in 4 files (`KeepAwake`, `HubEnsure`, `AmphetamineControl`, `ScriptedMediaProvider`) | S | none |
| F21 | Views | 6 terminals × 7 layouts × per-pane agent+cwd | ❌ **missing** | M | F20 (shares command-runner) |
| F22 | Floating widgets | 5 tear-off widgets, per-project position memory | ❌ **missing** — one incidental `widget` string in `PillChromePolicy`, no infrastructure | M | F6 for content |
| F23 | Agent Board | Auto-sorted floating kanban | ❌ **missing** — `PillView` has an "Agent board" MARK section, but it is an in-panel list, not a kanban and not floating | M | F6 |
| F24 | Focus Inbox | Ranked attention queue | ❌ **missing** — `staleAsks` is the nearest existing concept and is a good seed | S | F23 |
| F25 | Notifications (session events) | Approval, >30s completion, subagent, 2-min reminder, runaway process | 🟡 **partial** — `ShannonNotifier` fires on entropy collapse + gate ask. No completion / reminder / runaway alerts. **Runaway detection is nearly free** given `SystemResources.swift` already samples CPU/mem/disk | S–M | F6 for per-session attribution |
| F26 | Sound packs & quiet hours | Per-agent packs, custom AIFF/WAV/CAF, quiet hours | ❌ **missing** — no `quietHours` anywhere | S | F25 |
| F27 | Parallel agent handling | Prompt stacking, attention flags, row limits | 🟡 **partial** — `AgentActivitySummary` handles multiple agents, `busy`/`primary`/`busyCount`. No prompt stacking, no row-count setting | S | F10 |
| F28 | Appearance / Size settings | Opacity, depth, colors, widths, density, text size | 🟡 **partial** — `AgentStyleCatalog` gives per-agent brand colors (Science amber ≠ SuperGrok purple), `PillPanelHeight` handles sizing. No user-facing controls | S | W0 prefs |
| F29 | Settings tabs | 12 tabs incl. Doctor | 🟡 **partial** — 5 sections, single scroll. `--probe` is effectively an unexposed Doctor | S | all |
| F30 | Sparkle updates | Signed appcast | ❌ **missing** — Homebrew Cask/Formula + fastlane exist instead. Arguably sufficient for Shannon's distribution model | S | — |
| F31 | 25-agent breadth | Per-agent capability ledger | 🟡 **partial** — 8 IDs whitelisted | M per agent | F8 |

### Shannon-only surfaces — do not regress these while chasing parity

These have no AgentPeek counterpart. Parity work must not break them:

- **Shannon entropy collapse detection** with provenance and integrity gating.
- **Head-gesture confirm** (nod/shake to allow/deny).
- **On-device voice command dictation.**
- **System resource HUD** (CPU/GPU/RAM/SSD/temp).
- **Native keep-awake** tied to agent activity.
- **Pet companion** persistence layer.
- **FlexAIDdS / DatasetRunner benchmark surface** in the menu bar popover.

Note the `EntropyIntegrity` / `GateEntropyClock` discipline — refusing to display
a number whose measurement time cannot be proven. Reuse that exact pattern for
token and quota data in W2 rather than inventing a second one.

---

## 5. Parallel work plan

**Framing:** Shannon is personal tooling, and AgentPeek will be installed on the
same machine. That changes two things about how these streams should run:

1. **AgentPeek is the reference implementation, available live.** Where a feature
   description is ambiguous, the answer is on screen — install it, trigger the
   behavior, and copy it. Every stream below has a *"resolve by observation"*
   note listing what to go look at rather than guess.
2. **No need to cover 25 agents.** Build readers for the agents actually in use
   on this machine — Claude Code, Codex, Grok, Cursor, Cowork. AgentPeek covers
   the long tail already.

### 5.1 The merge-conflict hazard map — read this first

`Pill/` has a small number of god files that every feature naturally wants to
edit. If N agents work in parallel without discipline, they all edit these same
files and every merge conflicts:

| File | Lines | Why every stream wants it |
|---|---:|---|
| `Pill/Sources/ShannonPill/PillView.swift` | **1655** | Every new panel surface adds a section here |
| `Pill/Sources/PillCore/AgentIngest.swift` | **1594** | Every new agent source touches ingest |
| `Pill/Sources/ShannonPill/MenuBarPopoverView.swift` | **1214** | Every new menu-bar readout adds a section here |
| `Pill/Sources/PillCore/AgentActivity.swift` | **1093** | The single session model every stream must extend |
| `Pill/Sources/PillCore/ShannonPreferences.swift` + `…Store.swift` | 220 | Every new setting adds keys |
| `Pill/Sources/ShannonPill/SettingsView.swift` | 228 | Every new setting adds UI |
| `Pill/Sources/ShannonPill/ShannonPillApp.swift` | 446 | Every new subsystem needs `@main` wiring |
| `Pill/Package.swift` | 43 | Every new module adds a target |
| `Pill/Sources/PillCore/AgentStyle.swift` | 334 | Every new agent adds a style entry |
| `Pill/Sources/PillCore/ShannonNotifier.swift` | 130 | Every new alert type |

**These ten files are the entire risk surface.** Everything else is either a leaf
or a new file and can be touched freely.

### 5.2 Rule: one blocking stream, then fan out

> **W0 must land and merge before any other stream starts. No exceptions.**
> W0 exists specifically to stop those ten files being contention points.

---

### **W0 — Shared scaffolding (BLOCKING · solo · no parallelism)**

Pure enabling work, zero features. Turns "edit a god file" into "add a new file".

1. **`AgentSession` model** in `PillCore` covering the F6 field set (agent,
   project, cwd, host terminal, state, elapsed, tokens, model, account, branch,
   files, commands, diffs, todos, subagents, events). Every field optional with
   an explicit *not-reported-by-this-source* sentinel. Keep
   `AgentActivitySnapshot` as a projection so nothing existing breaks.
2. **`SessionProviding` protocol + `SessionRegistry`** merge layer that reconciles
   N providers and preserves the existing `presence: .live/.observed/.offline`
   ranking so gate telemetry still outranks a frontmost guess. **This is the most
   important artifact in the plan** — every reader plugs in here and touches
   nothing else.
3. **Split the god views.** Extract `PillView` and `MenuBarPopoverView` into
   per-section files behind a `PanelSection` protocol + registry. Same for
   `SettingsView` (tab registry) and `ShannonPreferences` (namespaced per-feature
   structs). **Also extract `GateAskCard` and `GateInlineCard` into their own
   files** — they currently live inside the two god views and would otherwise
   collide with W6.
4. **`SubsystemRegistry`** in `ShannonPillApp` so subsystems self-register.
5. **Declare all planned targets in `Package.swift` up front**, even empty:
   `AgentReaders`, `UsageCore`, `DevServers`, `Routes`, `Workspaces`, `Surfaces`.
   No later stream should ever need to edit this file.
6. **Promote `ProcessGuard`** to the shared kill-safety primitive.

**Touches:** all ten hazard files. **Estimated:** ~1 week solo.
**Exit criterion:** `swift build` green, all 48 test files still passing, and a
throwaway "hello world" `PanelSection` can be added in a new file with one
registry line and no other edits.

---

### Streams W1–W7 — parallel *after* W0 merges

Each owns a disjoint directory. The only shared touchpoint is a one-line registry
registration, which merges trivially.

**W1 — Agent artifact readers** · owns `Sources/AgentReaders/**` · **L**
`SessionProviding` conformances reading agents' own on-disk state:
`~/.claude/projects/**/*.jsonl`, `~/.codex/sessions` rollouts, Grok/Cursor stores;
a shared `FSEventsWatcher` incremental tail; git branch from session cwd.
Ship **Claude Code + Codex first, correctly** — add one reader per PR after.
*Resolve by observation:* compare Shannon's parsed session rows against
AgentPeek's for the same live session; any field AgentPeek shows and Shannon
doesn't is a parsing bug with a known-good oracle sitting next to it.

**W2 — Usage, quota & cost** · owns `Sources/UsageCore/**` · **L**
Provider 5h/7d windows with countdown, local token+cost aggregation, daily
history, gauges, 14-day chart, donut, threshold alerts and spend caps. Reuse the
existing `SmoothLoadBar` / `SmoothCoreBar` / `SparklineView`.
**Hard rule:** never synthesize a quota % from raw counters — keep provider
windows, raw local totals, and cost as three distinct types, exactly as
`EntropyIntegrity` already treats unproven entropy.
*Resolve by observation:* AgentPeek's numbers for the same account are the
ground-truth fixture. Diff against them.

**W3 — Dev servers** · owns `Sources/DevServers/**` · **M**
Enumerate listeners on 3000–9999 via `proc_pidinfo`/`libproc` (same process-table
machinery `TerminalAgentProbe` already uses — prefer this over shelling to
`lsof`). Framework/runtime classification, project from cwd, uptime from process
start; open / copy URL / copy port / jump / stop via `ProcessGuard`.
**Cleanest stream, zero coupling — start this one first.**

**W4 — Quick Routes + Fast Actions** · owns `Sources/Routes/**` · **M**
Declarative per-agent path catalog (skills/agents/commands/rules/plugins/config/
hooks/MCP/logs/sessions/db/root), existence-checked, missing routes rendered
dimmed and disabled, **never created**. Plus saved shell commands in a login
shell from `$HOME` with live status and last-line-on-failure.
*Resolve by observation:* AgentPeek's Quick Routes list is the path catalog —
transcribe it (it is also fully enumerated in §3 of this doc and in `llms.txt`).

**W5 — Floating surfaces** · owns `Sources/Surfaces/**` · **L**
Agent Board kanban (Active/Attention/Finished, auto-sorted, movable, resizable,
collapsible to a pill); tear-off widgets (Todos, Usage, Transcript, Subagents,
Tools) with per-project position memory; Focus Inbox ranking seeded from the
existing `staleAsks` concept. Reuses `PillWindowController`'s non-activating
panel pattern — **read it, do not edit it.**

**W6 — Permissions, questions & plans** · owns `ConfirmationController.swift`,
`GateApprovalClient.swift`, new `Sources/Permissions/**` · **M**
⌘A/⌘N/⌥A/⌥T shortcuts plus global answer-frontmost hotkeys; diff and command
rendering in the prompt card; prompt stacking with arrow navigation; structured
multi-part questions, plan Approve/Reject, reject-with-feedback.
**This is the one stream doing surgery on existing good logic rather than adding
new modules — assign a careful agent and keep the blast radius explicit.**
Blocked on W0 extracting the two Gate cards into their own files.

**W7 — Notifications, sounds, Doctor, Settings tabs** · owns
`ShannonNotifier.swift` + `Sources/Notifications/**` · **M**
Turn-complete (>30s), subagent-finished, 2-minute unanswered reminder, runaway
process alert (**nearly free** — `SystemResources.swift` already samples
CPU/mem/disk), per-event toggles, sound packs with per-agent override, custom
AIFF/WAV/CAF import, quiet hours, test button. Promote the existing `--probe`
output into a **Doctor** settings tab.

### 5.3 Dependency graph

```
                    W0  (blocking, solo, ~1 week)
                     │
   ┌──────┬──────┬───┴──┬──────┬──────┬──────┐
   W3     W4     W7     W6     W1     W2     W5
 servers routes notifs perms readers usage surfaces
                        │      │      │      │
                        └──────┴──────┴──────┘
              W2 and W5 consume W1's model via protocol —
              develop against fixtures, integrate at the end.
```

**If you cannot run all seven:** W3 → W4 → W1 → W2 → W7 → W6 → W5.
W3 and W4 are pure additive wins that prove the W0 scaffolding works before
committing an agent to the long W1/W2 haul.

---

## 6. Not worth building

| Item | Why skip |
|---|---|
| **Direct Chat / ACP follow-up prompts (F12)** | Largest single item in the matrix and it requires deliberately reversing Shannon's read-only-bridge decision (*"a readout, not an RPC surface"* — a security property, not an oversight). AgentPeek is installed; use it for this. Revisit only for Claude Code + Codex if it becomes a daily annoyance. |
| **25-agent breadth (F31)** | Build the 4–5 agents actually used on this machine. The long tail is what the AgentPeek license is for. |
| **Cursor account monthly usage** | Requires riding Cursor's web session. Fragile, breaks on their auth changes, and is the least valuable gauge. |
| **Aider analytics log, Devin desktop, Antigravity, ZCode et al.** | Not in use. Pure cost. |
| **Sparkle updates (F30)** | Homebrew Cask + `fastlane/` already exist and are the right distribution channel for a personal tool. |
| **Notification mirroring** | Already blocked at the platform level (`BLOCKED.md` §3). No macOS API exists. Do not reopen. |
| **Now Playing / MediaRemote** | Entitlement-dead since macOS 15.4 and orthogonal to agent monitoring. Consider **removing** it to shrink the surface — it is currently carrying `NSAppleEventsUsageDescription`, Automation prompts, and a composite provider for no parity benefit. |
| **AirDrop, AirPods battery, in-ear detection, stem presses** | No third-party API on any of them (`BLOCKED.md` §4, §8). |

---

## 7. Entitlements, permissions and private APIs

**Good news first: the notch itself needs nothing.** `NotchGeometry.swift` uses
`NSScreen.safeAreaInsets` + `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` — all
public API. There is **no private notch API** and none is required. Shannon
already solved this correctly.

| Capability | Requirement | Risk |
|---|---|---|
| Reading `~/.claude`, `~/.codex`, `~/.grok` (W1) | **None.** TCC protects Desktop/Documents/Downloads, not dotfolders in `$HOME` | ✅ clear |
| Reading `~/Library/Application Support/<agent>` (some agents) | May require **Full Disk Access** for certain paths | 🟡 detect and degrade gracefully; surface in the Doctor tab |
| Port enumeration via `libproc` (W3) | **None** for same-user processes | ✅ clear |
| Killing a dev server (W3) | **None** for same-user processes; keep the `ProcessGuard` check | ✅ clear |
| Fast Actions spawning a login shell (W4) | **None.** `Process()` already used in 4 files under Hardened Runtime | ✅ clear |
| Global hotkeys (W6) | Carbon `RegisterEventHotKey` — **no Accessibility needed**. Already linked and in use by `HotkeyMonitor` | ✅ clear |
| Notifications (W7) | Standard `UNUserNotificationCenter` authorization | ✅ clear |
| Writing agent hook config (F9, deferred) | No entitlement, but **mutates user config**. If ever built: mark the owned block, preserve everything else, uninstall only own entries | 🟡 handle with care |
| **App Sandbox** | **Must stay OFF** — IOKit power sources and MediaRemote are both unreachable sandboxed | ⛔ no Mac App Store; Developer ID + notarization or direct, same as AgentPeek |
| Head-gesture confirm (existing) | `NSMotionUsageDescription` TCC only — **there is no `com.apple.headphone-motion` entitlement**, that key does not exist. macOS 14+ | ✅ clear, but **unproven on hardware** |
| Voice dictation (existing) | Microphone + Speech Recognition TCC | ✅ clear, but **never run against a live mic** |
| MediaRemote (existing) | **Private entitlement Apple will not grant.** Gated since macOS 15.4 | ⛔ dead end — see §6 |

**Two unproven paths worth knowing about:** head-gesture confirm and voice
dictation are both fully built and unit-tested but have never executed against
real hardware. If either is load-bearing for the approval flow in W6, budget a
half-day of physical verification before relying on it.

---

## 8. Branch and worktree strategy

```bash
# Integration branch off main
git switch -c feat/agentpeek-parity main

# W0 lands here FIRST, solo, and merges before anything else starts.
# Then one worktree per stream, all branched from the post-W0 integration point:
git worktree add ../shannon-w1-readers  -b feat/parity/w1-readers  feat/agentpeek-parity
git worktree add ../shannon-w2-usage    -b feat/parity/w2-usage    feat/agentpeek-parity
git worktree add ../shannon-w3-servers  -b feat/parity/w3-servers  feat/agentpeek-parity
git worktree add ../shannon-w4-routes   -b feat/parity/w4-routes   feat/agentpeek-parity
git worktree add ../shannon-w5-surfaces -b feat/parity/w5-surfaces feat/agentpeek-parity
git worktree add ../shannon-w6-perms    -b feat/parity/w6-perms    feat/agentpeek-parity
git worktree add ../shannon-w7-notifs   -b feat/parity/w7-notifs   feat/agentpeek-parity
```

Worktrees rather than clones: one `.git`, one SwiftPM cache warm-up, and
`git worktree list` gives an honest picture of who is where.

**Rules for the swarm:**

- **Never rebase onto `main`** mid-stream. Integrate at `feat/agentpeek-parity`.
- **A stream that needs to edit a file outside its owned directory stops and
  files a request against W0's owner.** It does not edit in-stream. This is the
  single rule that keeps the merge cost near zero.
- **Each stream must keep `swift build` green and the 48 existing test files
  passing** before opening a PR. There is a real test suite here — do not let
  parallel work erode it.
- **Merge order at the end:** W3, W4, W7 (additive, low risk) → W1 → W2 → W6 → W5.

---

## 9. Sources

Shannon: local tree at `~/Projects/Shannon`, `Pill/README.md`, `Pill/BLOCKED.md`,
`Pill/Package.swift`, `Pill/Resources/Info.plist`, verified `swift build`,
`git log`, `gh repo list`.

AgentPeek (all fetched 2026-07-25, all server-rendered, none blocked):
[llms.txt](https://agentpeek.app/llms.txt) ·
[notch](https://agentpeek.app/notch/) ·
[menu-bar](https://agentpeek.app/menu-bar/) ·
[token-usage](https://agentpeek.app/token-usage/) ·
[permissions](https://agentpeek.app/permissions/) ·
[prompts](https://agentpeek.app/prompts/) ·
[dev-servers](https://agentpeek.app/dev-servers/) ·
[fast-actions](https://agentpeek.app/fast-actions/) ·
[quick-routes](https://agentpeek.app/quick-routes/) ·
[views](https://agentpeek.app/views/) ·
[widgets](https://agentpeek.app/widgets/) ·
[agent-board](https://agentpeek.app/agent-board/) ·
[parallel-agents](https://agentpeek.app/parallel-agents/) ·
[notifications](https://agentpeek.app/notifications/) ·
[dynamic-island](https://agentpeek.app/dynamic-island/) ·
[agent-monitor](https://agentpeek.app/agent-monitor/)

`agentpeek.app/docs/` was not fetched separately; `llms.txt` enumerates the full
docs route list and carries the same capability detail in denser form.
