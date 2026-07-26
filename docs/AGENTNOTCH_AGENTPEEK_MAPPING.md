# AgentNotch + AgentPeek → Shannon mapping

Category parity (defining mechanics), not pixel clones. All fields fail-closed.

## Defining outcomes

| Outcome | AgentNotch | AgentPeek | Shannon (shipped) |
|---|---|---|---|
| Multi-agent fleet | Notch peeks multi-session | Board / island multi-session | `AgentLiveSurfaceLogic.fleet` / `rankedAgentSurfaces`; roster via `SessionContentPresenter.cardsFromAgents` |
| Needs-you first | Waiting for approval peeks | Board “needs you” column | Attention rank needsYou → working → finished → idle; pending asks elevate |
| Live tool / activity line | Edited/ran/read lines | Tool calls / activity | `classifyTool` + present-tense `activityLine`; badge tool raw when working |
| Inline Approve/Deny | Notch Deny/Approve | In-notch permissions | `GateAskCard` (pill) + `GateInlineCard` (menu bar) via `GateAskActionCopy` |
| Hub offline honesty | N/A (local only) | Local-first | Buttons disabled + offline copy from `GateAskActionCopy.macGateAffordance` |
| Project / branch / model | Session chips | Session board density | `SessionContentCard.metaLine` from `AgentSession` (artifact readers + gate merge) |
| Usage / context % | Context gauge when real | Usage when readable | `AgentUsageSnapshot` / tokens on session; chip only when sourced; primary-only collapsed |
| Quiet idle | Minimal notch | Quiet island | `Shannon · idle` via `collapsedStatusLine` when no actionable focus |
| Multi-agent density | “3 agents” peeks | Multi session glance | `collapsedActiveCount` chip + `"N agents · activity"` when working fleet |
| Completion | Ready for review | Finished/done board | `task_complete` → finished / badge `done` / `Done · Name` |
| Entropy | — | — | **Shannon differentiator** — FluidEntropyRail / provenance; never fake H |

## Shared wording (no dual-HUD drift)

| Token | Source |
|---|---|
| needs you / working / done / live | `AgentAttentionCopy` → `AgentLiveSurfaceLogic.badgeLabel` → `AgentLiveChrome` |
| Approve / Deny / needs approval | `GateAskActionCopy` → GateAskCard + GateInlineCard + phone/pad |
| Collapsed focus | `AgentLiveSurface.collapsedFocus` / `SessionContentPresenter.collapsedStatusLine` |

## Surfaces

| UI | Presenter |
|---|---|
| Collapsed pill | `primaryFocus` / `collapsedStatusLine` / usage + count chips |
| Expanded board | `rankedAgentSurfaces` + companions + entropy rails |
| Menu-bar roster | `SessionContentPresenter.cardsFromAgents` + badges/meta/usage |
| Pulled sessions | `SessionContentPresenter.cards` (artifact; live agents de-duped) |
| Approvals | GateAskCard (expand) / GateInlineCard (popover) |

## Explicit non-parity (by design)

- OTEL/OTLP receiver (AgentNotch) — not required; Shannon uses gate socket + disk readers
- Full 25-agent AgentPeek matrix — only agents with local signals
- Chat window / kanban board / jump-to-terminal — out of scope
- Invented token/cost when source silent — fail-closed

## Tests pinning product class

- `AgentNotchAgentPeekParityTests` — scenarios (a)–(e) + optional fields + dual-HUD tokens
- `SessionContentPresenterTests`, `AgentLiveSurfaceTests`, `SessionUIWiringTests`
