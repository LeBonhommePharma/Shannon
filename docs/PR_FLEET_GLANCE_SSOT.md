# PR plan: Fleet glance SSOT (AgentNotch density + per-agent H)

## Goal

Make Shannon’s dual HUD (collapsed island + expanded board + menu-bar popover)
feel as **smooth / simple** as AgentNotch while keeping **per-agent Shannon
entropy** as the fail-closed differentiator.

## Problem

- Pill and menu-bar each re-run `EntropyProvenance.resolve` / `resolveAll` /
  `companionDeltas` with slightly different agent-id sets → dual-HUD drift risk
  and wasted work per tick.
- Menu-bar rows can still re-`resolveForAgent` when a map miss occurs.
- Collapsed island shows **fleet** H only; research goal is glanceable
  **per-agent** H when measured (primary busy agent preferred).

## Non-goals

- OTEL/OTLP ingest, chat, kanban, pixel-perfect AgentNotch clone
- Inventing H when sources are silent
- Pets / Now Playing redesign

## Design

### Pure SSOT: `FleetGlancePresenter` (PillCore)

One call per UI tick produces:

| Field | Rule |
|-------|------|
| `fleetReading` | Single `EntropyProvenance.resolve` |
| `agentIds` | Unified admission / prefer-busy / optional listed override |
| `liveAgentIds` | Admitted live set (sole-live fleet bridge attach) |
| `liveReadings` | One `resolveAll` for `agentIds` |
| `rowReadings` | `preferredRowReading(live, memory)` per id (no second bridge resolve) |
| `companionDeltas` | Derived from measured `liveReadings` only (no re-resolve) |
| `collapsedEntropyLabel` | Measured-only chip; prefer primary agent display bits, else fleet |
| `showPerAgentEntropyStrip` | `ExpandedBoardDensity` + any displayable H in `rowReadings` |

### Wiring

- `PillView`: replace private `fleetReading` / `agentReadings` / `agentCompanionDeltas`
  with one `fleetGlance` snapshot; collapsed H chip uses `collapsedEntropyLabel`.
- `MenuBarPopoverView`: same snapshot for `reading` + `agentReadings`.
- `MenuBarAgentRoster`: consume map only (no ad-hoc `resolveForAgent` fallback).

## Tests

- Synthetic demo → no collapsed H label; no measured row labels from fleet alone
- Measured primary agent → chip uses that agent’s bits (not a foreign fleet number)
- Prefer-busy resolve set matches product density
- Companion deltas only for measured ids; strip suppress when no displayable H
- Structural: PillView / MenuBarPopoverView call `FleetGlancePresenter.snapshot`

## Ship criteria

1. Pure tests green
2. Package build has no new dual resolve path in those views
3. Fail-closed entropy rules unchanged (synthetic never alarms / never paints measured H)
