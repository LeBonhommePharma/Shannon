# Shannon pet — implementation backlog

Chunked TODOs for the Shannon 10‑minute loop (investigate → append → implement).
Each item is grounded in suite runs, live `~/.codex/pets` resolve, or shipped
source inspection. **Do not treat this as a design doc** — pick from the top
when scheduling work.

**Loop protocol:** each fire may add 0–3 new open items (B/E/O/T) from evidence,
then implements **one** open item (prefer B → E → O → T). Cross-cutting
Pill/session work goes to `docs/ENHANCEMENT_BACKLOG.md` (ENH-018+).

Test baseline (must stay green while implementing):

- Pill: `swift test --filter 'Pet|Companion|Desktop|Atlas|CodexMotion|Package|PetPaths'`
- Hub: `python -m pytest hub/tests/test_pet_*.py -v`

---

## Bugs / correctness

- [x] **B1 — Packages missing `spriteVersionNumber` never draw on the atlas path**  
  Observation: live `~/.codex/pets/oc-an` and `stitch` have valid `spritesheet.webp`
  + `pet.json` but omit `spriteVersionNumber`. With `requireV2: true` (what
  `CompanionDrawMode` / desktop companion use) resolve falls to procedural.
  Without requireV2 they resolve as version=1.  
  Work: either treat “sheet present + complete atlas geometry” as drawable, or
  default missing version to 2 when sheet dimensions match v2 grid; add
  migrate/note for hatch-pet to always write version.  
  **Done:** `inferredSpriteVersion` / `infer_sprite_version` — missing version +
  sheet → v2 (note recorded); explicit 1 stays 1; hub+Pill tests + live oc-an.

- [x] **B2 — `CompanionBubbleText.Signals(state:)` drops `lastOutcome`**  
  Observation: `init(state:)` hard-codes `lastOutcome = nil`, so bubble copy
  cannot restate review/failed from roster outcomes even when
  `state.codexMotion` already mapped them.  
  Work: plumb outcome through `CompanionState` (or re-derive from motion) so
  bubble detail can show task-complete / failed evidence honestly.  
  **Done:** `CompanionState.lastOutcome` stored; `Signals(state:)` carries it;
  failed/review detail prefers task → outcome evidence (`Failed` /
  `Task complete`) → status/who; unit tests via state + roster lastOutcomes.



- [x] **B3 — Board companions always atlas-bind package id `"shannon"`**  
  Observation: `CompanionGlyph` passes `packagePetId: PetPackageResolver.defaultPetId`
  for every agent. Live packages include `grok`, `bonhomme`, `firebear`, etc.,
  but per-agent surfaces never select them.  
  Work: map agent id / style → preferred package id (with procedural fallback);
  optional preference override.  
  **Done:** `PetPackageBinding` + `PetPackageResolver.preferredPackageId`;
  `CompanionGlyph`/`Badge` map per agent; desktop selector agent map + override.

---

## Enhancements / features

- [x] **E1 — Desktop pet package picker (Settings)**  
  Observation: desktop companion always uses default `"shannon"` package;
  `~/.codex/pets` lists 6 drawable v2 packages (shannon, bonhomme, bonhomme-cat,
  collapse-cat, firebear, grok). No UI to choose.  
  Work: `ShannonPreferences.desktopPetId` + Settings picker fed by
  `list_pet_packages` / Swift list helper; persist and re-resolve on change.  
  **Done:** `desktopPetId` pref + store callback; `listPetPackageIds` pure list;
  Settings package picker; desktop companion re-resolves on change.


- [x] **E2 — Toggle hide/show desktop companion (persisted)**  
  Observation: desktop pet always shows on launch; menu only has “Show Desktop
  Pet” reassert, no hide / no Settings toggle.  
  Work: preference + menu checkmark; honor at launch.  
  **Done:** `ShannonPreferences.showDesktopCompanion` (default true) + store;
  menu checkmark toggle; Settings toggle; launch honors preference; hide blocks
  reassert until show.

- [x] **E3 — Multi-agent desktop carousel or stack**  
  Observation: `DesktopCompanionSelector` shows only `roster.first` (working
  first). Secondary live agents are invisible on the floating surface (still on
  notch board).  
  Work: click/cycle through roster, or small stack of badges for top N busy.  
  **Done:** `DesktopCompanionCycle` pure helpers + selector extensions; `DesktopCompanionModel.cycleToNext` + dots/click; sticky agent id; unit tests.

- [x] **E4 — Click bubble → expand notch / focus agent row**  
  Observation: bubble is status text only; non-goal excluded full Codex chat,
  but a light “surface handoff” is missing.  
  Work: click bubble or pet → `PillWindowController.expand()` + scroll/highlight
  matching agent if any.  
  **Done:** `DesktopCompanionHandoff` focus-id helper; desktop click →
  `performActivate` → `PillWindowController.expand(focusAgentId:)`; board row
  highlight via `CompanionBoardView.focusedAgentId`.


- [x] **E5 — Document `SHANNON_PETS` unified home for operators**  
  Observation: `PetPaths` / `pet_paths` support `SHANNON_PETS` (packages at root,
  agents under `agents/`), but README / CLAUDE.md still describe only dual
  defaults.  
  Work: short operator section in Pill README + hub pet_manager docstring
  examples with `/Users/…/.codex/pets`.  
  **Done:** Pill README “Pet paths (operators)” + `hub/pet_manager.py` /
  `hub/pet_paths.py` docstrings with `SHANNON_PETS=$HOME/.codex/pets` layout.

---

## Optimizations

- [x] **O1 — Desktop companion refresh cadence**  
  Observation: `DesktopCompanionModel` binds `objectWillChange` from activity +
  bridge **and** a 2 s timer that always rebuilds presentation. Quiet machines
  still wake every 2 s.  
  Work: timer only when a sleepy threshold is near, or coalesce to activity
  ticks + 30 s sleepy poll.  
  **Done:** `DesktopCompanionRefreshCadence` pure policy — quiet 30 s poll,
  2 s only within `nearSleepyWindow` of `sleepyAfter`; model reschedules on
  refresh; unit tests for interval selection + empty-roster quiet schedule.

- [x] **O2 — Cache `PetPackageResolver` results per process**  
  Observation: `CompanionView.resolvePackageOnce` caches per view instance, but
  each new row re-hits disk; `list_pet_packages` / multi-surface may re-parse
  all roots.  
  Work: process-wide cache keyed by (petId, roots mtime) with invalidation on
  path env change.  
  **Done:** `PackageResolveCache` on `PetPackageResolver` — key =
  (petId, requireV2, roots paths, roots/package mtime, path-env fingerprint,
  memory path); global wipe when path-env fingerprint changes; `clearResolveCache`
  + hit/miss counters; pure cache tests in `PetPackageResolverCacheTests`.
  `CompanionView.resolvePackageOnce` benefits via shared `resolve`.


- [x] **O3 — Align Swift package roots with Python repo mirrors intentionally**  
  Observation: Python `package_roots` appends `hub/` and `repo/pets` mirrors;
  Swift `PetPaths.packageRoots` does not. Tests pass but list/resolve can differ
  by environment.  
  Work: either add optional mirror roots on Swift for parity, or document
  “Python-only dev mirrors” and exclude from production resolve docs.  
  **Done:** Swift opt-in via `includeRepoMirrors` / `repoRoot` /
  `$SHANNON_PETS_REPO` (appends `<repo>/hub` then `<repo>/pets`); production
  default remains mirrors-off. Python accepts same env (else `__file__` hub).
  Path-list parity tests on both sides.

---

## Test / coverage gaps (found during pass)

- [x] **T1 — Live spritesheet drawable check for real `shannon` webp**  
  Observation: package resolve tests assert metadata + path; no test loads
  `~/.codex/pets/shannon/spritesheet.webp` through `PetAtlasRenderer.frameImage`
  (geometry/crop).  
  Work: macOS-only test: if live sheet exists, `isDrawable` and one crop
  non-nil for `.idle` / `.running`.  
  **Done:** `testLiveShannonSpritesheetDrawableIfPresent` in PetPackageResolverTests;
  XCTSkip when sheet/AppKit missing so CI without pets stays green.

- [ ] **T2 — Swift ↔ Python motion matrix golden file**  
  Observation: both sides claim parallel precedence; no shared fixture asserts
  identical labels for the same signal table.  
  Work: JSON cases consumed by both `PetCodexMotionTests` and
  `test_pet_codex_motion.py`.

- [x] **T3 — Bubble honesty when motion is review/failed but mood is idle**  
  Observation: matrix tests cover Signals; fewer cases build from real
  `CompanionState` after roster outcome merge.  
  Work: roster + activity → bubble text golden for review/failed.  
  **Done:** `moodDisplayWord` / moodLine never claim resting/sleeping when
  codexMotion is review (`ready`) or failed (`uneasy`); failed bubble mood
  always `.wary`; roster+activity goldens in CompanionBubbleHonestyT3Tests.

---

## Residual risks (not backlog bugs)

- Desktop always-on-top above fullscreen Keynote/Screen Sharing cannot be proven
  in unit tests; policy tests cover AppKit level/collectionBehavior only.
- Migrating agent memory onto `$SHANNON_PETS/agents` needs an explicit copy/symlink
  step — not automated (by design).

---

## Run evidence (this pass)

| Suite | Result |
|-------|--------|
| Pill pet filter | 122 PillCore + 5 ShannonPill DesktopCompanion window tests, 0 failures |
| Hub `test_pet_*.py` | 111 passed (later loop: 114) |
| Live `~/.codex/pets` | shannon/bonhomme/bonhomme-cat/collapse-cat/firebear/grok → v2 OK; oc-an/stitch → v1 only (B1) |
| B2 (2026-07-26) | CompanionBubbleText + CompanionState lastOutcome plumb; see DesktopCompanionTests |
| T3 (2026-07-26) | moodDisplayWord + roster/activity bubble goldens for review/failed vs idle mood |
