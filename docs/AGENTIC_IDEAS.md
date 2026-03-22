# Agentic-First UX Vision

Epic tracker: [#1113](https://github.com/jsmestad/minga/issues/1113)
Release planning: [#1119](https://github.com/jsmestad/minga/issues/1119)

## Origin

This document captures a brainstorming session (March 2026) about what makes Minga different from every other editor. The starting point was a concrete UX problem: the tab/buffer model is confusing, the agent chat UI feels like an afterthought, and the status bar breaks when switching between buffer and agent views. We fixed the immediate bugs (#1051, #1047) and then asked a bigger question: what would a best-in-class agentic-first editor look like if we designed from first principles instead of copying VS Code?

Five rounds of consultation with the `swift-expert` and `archie` subagents produced 33 ideas across 7 categories. Not all of these will ship. Many are intentionally provocative. The goal is to have a rich design space to pull from as the product evolves.

## The Core Thesis

The BEAM is not just Minga's engine. It is the product differentiator.

Every idea in this document leverages something the BEAM uniquely provides (process introspection, supervision trees, message-passing concurrency, hot code loading, Erlang distribution) combined with native macOS capabilities (Metal GPU rendering, system APIs like SFSpeechRecognizer and AVAudioEngine, NSStatusItem, haptic feedback) that Electron-based and web-based editors cannot touch.

No VS Code extension, no Neovim plugin, no Emacs package can do what a BEAM-native editor with a Metal-native frontend can do. That asymmetry is the moat.

## Infrastructure Foundations

Four infrastructure pieces are the load-bearing walls. Build these correctly, build them once, and every feature in this document snaps on top. Build features without them and you create ad-hoc workarounds that violate the "build it right" rule.

### 1. BufferChangedEvent with Source Identity ([#1093](https://github.com/jsmestad/minga/issues/1093))

The `:buffer_changed` event gains two fields: `delta` (what changed, an `EditDelta`) and `source` (who changed it: `:user`, `{:agent, session_id, tool_call_id}`, `{:lsp, server}`, `{:formatter}`). This is the atomic unit of edit provenance. Every edit-aware feature reads this event.

**Enables:** Provenance Undo (#1108), Ghost Cursors (#1082), Edit Timeline (#1083), Agent Sonar (#1096), Code Autobiography (#1101)

### 2. Event Recording System ([#1120](https://github.com/jsmestad/minga/issues/1120))

A `Minga.EventRecorder` GenServer subscribes to `Minga.Events` and writes an ordered, queryable, persistent event log. Each event carries timestamp, source, scope, and payload. Stored in SQLite or compressed JSONL with configurable retention.

**Enables:** Edit Timeline (#1083), Session Archaeology (#1086), Total Recall (#1111), Code Autobiography (#1101), Conversation-Driven Refactoring (#1106), Institutional Memory (#1097)

### 3. Process Metrics Collector ([#1122](https://github.com/jsmestad/minga/issues/1122))

A `Minga.SystemObserver` GenServer with three collection tiers: always-on supervisor monitors (restart detection), on-demand process tree polling (memory/queue/reductions at 1Hz), and domain state queries (agent sessions, cost tracking). One collector serves five visualization features.

**Enables:** Resilience-as-UX (#1109), BEAM Observatory (#1081), Supervision Lens (#1087), Living Architecture (#1098), The Biome (#1112)

### 4. Global Buffer Registry ([#1073](https://github.com/jsmestad/minga/issues/1073))

An ETS table mapping `file_path -> pid` with reference counts. Buffers are globally addressable and lifecycle-managed. Any workspace, window, or agent that opens a buffer increments the refcount. Closing a tab decrements, not `GenServer.stop`. This replaces the current per-tab buffer ownership model.

**Enables:** Workspace model (#1073), Tab grouping (#1079), Spatial Navigation (#1107), Code Cartography (#1088), Ghost Cursors (#1082, needs to find buffers agents are editing)

## Architectural Verdicts

Archie analyzed whether features represent competing paradigms (pick one) or compatible layers (build in order). This determines what can ship together.

### Tab/Workspace Navigation: VIEWS (not competing)

The five tab grouping approaches (#1075-#1079) are three different rendering strategies on the same BEAM data model. The data model is a `WorkspaceBar` holding `[Workspace{id, label, tab_bar: TabBar.t()}]` with an `active_workspace_id`. The Swift/TUI frontends pick how to render it:

- Arc Spaces (#1075): show only the active workspace's tabs
- Multi-Row (#1076): workspace capsules in top row, tabs in bottom row
- Tab Sections (#1077): all tabs in one row with group separators
- Sidebar List (#1078): vertical list in sidebar grouped by workspace
- Progressive Hybrid (#1079, recommended): combines workspace dropdown + tab sections + picker

You build the BEAM model once. Different frontends (or the same frontend with a user preference) can render it differently.

### Temporal Recording: LAYERED (build in order)

Three scales of "remember what happened" share an event format but differ in storage granularity:

- Scale A: Edit Timeline (#1083): per-file, source-tagged edit events
- Scale B: Session Archaeology (#1086): per-agent-session with file snapshots
- Scale C: Total Recall (#1111): everything, globally queryable by time range

Build A first (source-tagged edit events in Buffer.Server via #1093). B uses them. C wraps them in a global log (#1120). The critical decision: design the `EditEvent` struct for Scale C's needs from day one, even if you only store at Scale A's granularity initially.

### Process Visualization: VIEWS (one collector, multiple renderings)

- Resilience-as-UX (#1109): always-on restart detection (cheapest tier)
- BEAM Observatory (#1081): full process tree with metrics (on-demand polling)
- Supervision Lens (#1087): agent-focused dashboard (domain state queries)

One `SystemObserver` GenServer (#1122) serves all three. They're projections of the same process tree at different levels of detail.

### Agent Edit Awareness: LAYERED (design for the end state)

- Ghost Cursors (#1082): post-edit observation, shows where the agent is editing
- Agent Sonar (#1096): pre-edit interception, the agent reads its own blast radius

Ghost Cursors first, Sonar evolves it. The critical decision: ghost cursor edit broadcasts must be source-tagged and stored in a queryable registry (not fire-and-forget render hints), so Sonar can later query "which buffers have active agent edits?"

## Release Bundles

### Release 1: "Agent Transparency" (3-4 weeks)

The strongest differentiator. No other editor lets you watch an AI agent edit in real time, tag every edit by source, and scrub through the history.

| Ticket | Feature | Swift Effort | BEAM Effort |
|--------|---------|-------------|-------------|
| [#1093](https://github.com/jsmestad/minga/issues/1093) | BufferChangedEvent + source identity | None | 1 week |
| [#1108](https://github.com/jsmestad/minga/issues/1108) | Live Agent Edit Stream + Provenance Undo | Low (status bar only) | 1-2 weeks |
| [#1082](https://github.com/jsmestad/minga/issues/1082) | Ghost Cursors | Moderate (Metal overlay) | 1 week |
| [#1083](https://github.com/jsmestad/minga/issues/1083) | Edit Timeline | Moderate (new panel) | 1 week |

**Infrastructure built:** Event Recording System (#1120), Agent-to-Buffer.Server routing (BUFFER-AWARE-AGENTS Phase 1)

**Pivot safety:** If users hate "watching the agent work in real-time," disable the ghost cursor Metal overlay with one boolean. The edit timeline is passive history (useful regardless). Provenance undo is BEAM-only. Near-zero waste.

**Build order within release:**
1. #1093 (source-tagged events, unblocks everything)
2. #1108 (provenance undo, BEAM-only)
3. #1083 (edit timeline, new panel, independent of ghost cursors)
4. #1082 (ghost cursors, most novel Swift work, benefits from stable foundation)

### Release 2: "Editor Intelligence" (2-3 weeks)

Surfaces the BEAM's self-healing and introspection as visible UX. Answers "why is this editor built on the BEAM?" with something users can see and touch.

| Ticket | Feature | Swift Effort | BEAM Effort |
|--------|---------|-------------|-------------|
| [#1109](https://github.com/jsmestad/minga/issues/1109) | Resilience-as-UX | Low (health dot, toasts) | 1 week |
| [#1081](https://github.com/jsmestad/minga/issues/1081) | BEAM Observatory | Moderate-High (visualization) | 1 week |
| [#1110](https://github.com/jsmestad/minga/issues/1110) | Eval-in-Context | Low (reuses minibuffer) | 1 week |

**Infrastructure built:** Process Metrics Collector (#1122)

**Build order:** #1109 (cheap surface), #1110 (nearly done, Eval mode exists), #1081 (largest Swift effort)

### Release 3: "Workspace" (4-6 weeks)

Fixes the confusing tab/buffer model. Important for editor maturity, highest Swift-side effort.

| Ticket | Feature | Swift Effort | BEAM Effort |
|--------|---------|-------------|-------------|
| [#1073](https://github.com/jsmestad/minga/issues/1073) | Workspace model + Global Buffer Registry | Low-Moderate | 2-3 weeks |
| [#1079](https://github.com/jsmestad/minga/issues/1079) | Progressive hybrid tab grouping | Moderate-High (TabBarView rework) | 1 week |
| [#1107](https://github.com/jsmestad/minga/issues/1107) | Spatial Code Navigation | Low (Metal overlays) | 1-2 weeks |

**Infrastructure built:** Global Buffer Registry (#1073)

**Note:** Tab Grouping (#1079) is the only feature across all three releases that modifies existing Swift views (TabBarView). Everything else is purely additive. Design the grouped `TabBarState` so a single default group renders identically to the current flat layout. Then the BEAM controls whether grouping is active.

### Independent Features (ship anytime)

These have zero infrastructure coupling. Interleave between heavy releases as palate cleansers:

| Ticket | Feature | Effort |
|--------|---------|--------|
| [#1085](https://github.com/jsmestad/minga/issues/1085) | Menu Bar Companion | Small (pure Swift/macOS) |
| [#1092](https://github.com/jsmestad/minga/issues/1092) | Explain Mode | Small (command + existing agent) |
| [#1089](https://github.com/jsmestad/minga/issues/1089) | Whisper Channel | Small (AVFoundation input) |
| [#1090](https://github.com/jsmestad/minga/issues/1090) | Dream Mode | Medium (Task.Supervisor + agent) |
| [#1104](https://github.com/jsmestad/minga/issues/1104) | Adversarial Pair Programming | Medium (two agent sessions) |
| [#1103](https://github.com/jsmestad/minga/issues/1103) | Codebase Pulse | Small (telemetry to audio) |
| [#1110](https://github.com/jsmestad/minga/issues/1110) | Eval-in-Context | Small (can also ship standalone) |

## All Ideas by Category

### Practical & Ship-Soon

| # | Idea | Origin | Key Insight |
|---|------|--------|-------------|
| [#1108](https://github.com/jsmestad/minga/issues/1108) | Live Agent Edit Stream + Provenance Undo | Round 5 (practical) | Tag every edit by source. Undo everything an agent did with one command. |
| [#1109](https://github.com/jsmestad/minga/issues/1109) | Resilience-as-UX | Round 5 (practical) | Surface supervision self-healing as a visible feature, not a hidden implementation detail. |
| [#1110](https://github.com/jsmestad/minga/issues/1110) | Eval-in-Context | Round 5 (practical) | Evaluate Elixir in the running editor VM. The editor is its own REPL. |
| [#1085](https://github.com/jsmestad/minga/issues/1085) | Menu Bar Companion | Round 1 | NSStatusItem showing agent status. Know what your agents are doing without switching windows. |

### Workspace & Navigation

| # | Idea | Origin | Key Insight |
|---|------|--------|-------------|
| [#1073](https://github.com/jsmestad/minga/issues/1073) | Workspace Model Proposal | User request | Separate tabs (one file each) from workspaces (grouped contexts). Global Buffer Registry. |
| [#1075](https://github.com/jsmestad/minga/issues/1075) | Arc-style Spaces | Swift-expert R3 | Full workspace switching via sidebar strip. Strong for status awareness, weak for cross-cutting. |
| [#1076](https://github.com/jsmestad/minga/issues/1076) | Multi-Row Tab Bar | Swift-expert R3 | Workspace capsules top row, file tabs bottom row. Familiar but 24pt of mostly-empty chrome. |
| [#1077](https://github.com/jsmestad/minga/issues/1077) | Tab Sections | Swift-expert R3 | Visual separators in single row. Zero additional chrome, just structure. Recommended core. |
| [#1078](https://github.com/jsmestad/minga/issues/1078) | Sidebar Tab List | Swift-expert R3 | Vertical "Open Editors" panel. Good as optional, not a replacement. |
| [#1079](https://github.com/jsmestad/minga/issues/1079) | Progressive Hybrid | Swift-expert R3 | Combines workspace dropdown + tab sections + picker. Adapts complexity to the situation. |
| [#1107](https://github.com/jsmestad/minga/issues/1107) | Spatial Code Navigation | Round 4 | Navigate the codebase as a zoomable map. Modules positioned by dependency, not directory. |
| [#1088](https://github.com/jsmestad/minga/issues/1088) | Code Cartography | Round 2 | Zoomable dependency map with agent trails showing which files they touched and in what order. |

### Agent Intelligence

| # | Idea | Origin | Key Insight |
|---|------|--------|-------------|
| [#1082](https://github.com/jsmestad/minga/issues/1082) | Ghost Cursors | Round 1 | See the agent editing in real-time on your editor surface. Collaborative editing for human+agent. |
| [#1096](https://github.com/jsmestad/minga/issues/1096) | Agent Sonar | Round 3 (evolves #1082 + #1091) | The agent reads its own blast radius before editing. Multiple agents coordinate through shared impact data. |
| [#1084](https://github.com/jsmestad/minga/issues/1084) | Agent Resonance | Round 1 | Visual coupling between related sessions. Detect when two agents are working on connected code. |
| [#1099](https://github.com/jsmestad/minga/issues/1099) | Agent Choreography | Round 3 (evolves #1087) | Reusable multi-agent workflow pipelines. A choreography is a supervision tree. |
| [#1104](https://github.com/jsmestad/minga/issues/1104) | Adversarial Pair Programming | Round 4 | An agent that challenges your assumptions. A sparring partner, not a servant. |
| [#1106](https://github.com/jsmestad/minga/issues/1106) | Conversation-Driven Refactoring | Round 4 | Negotiate complex refactors in natural language. The refactoring plan is a first-class DAG. |

### Temporal & Memory

| # | Idea | Origin | Key Insight |
|---|------|--------|-------------|
| [#1083](https://github.com/jsmestad/minga/issues/1083) | Edit Timeline | Round 1 | Scrub through agent edit history like a video player. Each tool call is a timeline marker. |
| [#1086](https://github.com/jsmestad/minga/issues/1086) | Session Archaeology | Round 1 | Resumable agent context across launches. Branch a past session from any point. |
| [#1097](https://github.com/jsmestad/minga/issues/1097) | Institutional Memory | Round 3 (evolves #1090 + #1086) | Dreams that compound over weeks. Trajectory detection shows where the codebase is heading. |
| [#1101](https://github.com/jsmestad/minga/issues/1101) | Code Autobiography | Round 3 | Every function tells its story: origin, evolution, rejected approaches, key decisions. |
| [#1111](https://github.com/jsmestad/minga/issues/1111) | Total Recall | Round 5 (weird) | The editor that never forgets. Temporal workspace restoration, session replay, temporal code queries. |

### System Visualization

| # | Idea | Origin | Key Insight |
|---|------|--------|-------------|
| [#1081](https://github.com/jsmestad/minga/issues/1081) | BEAM Observatory | Round 1 | Native process tree visualization. `:observer.start()` reimagined as a first-class editor feature. |
| [#1087](https://github.com/jsmestad/minga/issues/1087) | Supervision Lens | Round 1 | Agent control room dashboard. Mission control for multi-agent workflows. |
| [#1098](https://github.com/jsmestad/minga/issues/1098) | Living Architecture | Round 3 (evolves #1081 + #1092) | Predictive process monitoring. "Your next keystroke will lag." Anomaly self-diagnosis. |
| [#1091](https://github.com/jsmestad/minga/issues/1091) | Code Seismograph | Round 2 | See the blast radius of your edit before you save. Ripple visualization from cursor. |
| [#1112](https://github.com/jsmestad/minga/issues/1112) | The Biome | Round 5 (weird) | Code as a living ecosystem. Prune dead code. Fertilize sick modules. Watch the garden grow. |

### Sensory & Ambient

| # | Idea | Origin | Key Insight |
|---|------|--------|-------------|
| [#1103](https://github.com/jsmestad/minga/issues/1103) | Codebase Pulse | Round 4 | Ambient audio synthesized from system vital signs. Test health = harmony. Complexity = dissonance. |
| [#1089](https://github.com/jsmestad/minga/issues/1089) | Whisper Channel | Round 2 | Voice interaction with agents. "Hey Minga, what would break if I renamed this function?" |
| [#1102](https://github.com/jsmestad/minga/issues/1102) | Ambient Awareness | Round 3 | The editor adapts to time, focus mode, typing rhythm, display size, battery state. |

### Meta & Learning

| # | Idea | Origin | Key Insight |
|---|------|--------|-------------|
| [#1092](https://github.com/jsmestad/minga/issues/1092) | Explain Mode | Round 2 | The editor narrates its own architecture. Click any UI element and learn what BEAM process backs it. |
| [#1105](https://github.com/jsmestad/minga/issues/1105) | Personal Knowledge Graph | Round 4 | Tracks what you know about the codebase, surfaces what you don't right when it matters. |
| [#1090](https://github.com/jsmestad/minga/issues/1090) | Dream Mode | Round 2 | Autonomous overnight maintenance. Run tests, find dead code, generate docs while you sleep. |
| [#1100](https://github.com/jsmestad/minga/issues/1100) | Shared BEAM | Round 3 | Multi-human collaboration via Erlang distribution. The BEAM's process model IS the collaboration model. |

### Infrastructure

| # | Idea | Origin | Key Insight |
|---|------|--------|-------------|
| [#1093](https://github.com/jsmestad/minga/issues/1093) | BufferChangedEvent + Source Identity | Pre-existing + release planning | The atomic unit of edit provenance. Every edit-aware feature reads this event. |
| [#1120](https://github.com/jsmestad/minga/issues/1120) | Event Recording System | Archie infrastructure analysis | Cross-process persistent event log. Foundation for 6+ temporal features. |
| [#1122](https://github.com/jsmestad/minga/issues/1122) | Process Metrics Collector | Archie infrastructure analysis | BEAM introspection GenServer. One collector serves 5 visualization features. |

## Dependency Graph

```
#1093 BufferChangedEvent + source identity
  └── #1108 Provenance Undo
  └── #1082 Ghost Cursors
  │     └── #1096 Agent Sonar (evolves ghost cursors)
  └── #1120 Event Recording System
        └── #1083 Edit Timeline
        └── #1086 Session Archaeology
        └── #1111 Total Recall
        └── #1101 Code Autobiography
        └── #1097 Institutional Memory

#1122 Process Metrics Collector
  └── #1109 Resilience-as-UX (always-on tier)
  └── #1081 BEAM Observatory (on-demand tier)
  └── #1087 Supervision Lens (domain query tier)
  └── #1098 Living Architecture (time-series + anomaly)
  └── #1112 The Biome (health composite)

#1073 Global Buffer Registry
  └── #1079 Tab Grouping
  └── #1107 Spatial Navigation
  └── #1088 Code Cartography

Independent (no infrastructure dependencies):
  #1085 Menu Bar Companion
  #1089 Whisper Channel
  #1090 Dream Mode
  #1092 Explain Mode
  #1099 Agent Choreography (needs agent routing, not registry)
  #1100 Shared BEAM
  #1102 Ambient Awareness
  #1103 Codebase Pulse
  #1104 Adversarial Pair Programming
  #1105 Personal Knowledge Graph (manual-only version)
  #1106 Conversation-Driven Refactoring
  #1110 Eval-in-Context
```

## Design Decisions Made

These decisions were made during the brainstorming session and should be honored during implementation:

1. **One BEAM data model, multiple renderings.** The five tab grouping approaches are VIEWS of the same `WorkspaceBar` struct. Build the model once; let frontends choose rendering. The macOS GUI might use the progressive hybrid; the TUI might use tab sections.

2. **Design events for the end state.** The `EditEvent` struct must carry source identity (`{:agent, session_id, tool_call_id}`) from day one, even if only Provenance Undo uses it initially. Retrofitting source tags later means touching every consumer.

3. **Ghost cursor broadcasts must be queryable.** Store active edit positions in an ETS table, not fire-and-forget events. Sonar needs to query "which buffers have active agent edits?" If ghost cursors are ephemeral render hints, the evolution to Sonar is a rewrite.

4. **Tab grouping renders flat when there's one group.** Design `TabBarView` so a single default group renders identically to the current flat layout. The BEAM controls whether grouping is active by sending 1 group (flat) vs N groups (grouped). This makes grouping opt-in and safely revertible.

5. **The Process Metrics Collector is demand-driven.** Always-on tier is trivially cheap (just process monitors). On-demand polling only activates when a visualization UI is open. Don't poll 200 processes at 1Hz when nobody's looking.

6. **Agent file association is automatic.** When an agent modifies files, those files appear in the agent's tab group automatically. The user doesn't manually organize. When the agent session closes, its files migrate to the manual workspace (they don't disappear).

## Where We're Trying to Go

The vision is an editor where:

- Agents are peers, not tools. They have presence (ghost cursors), agency (sonar, choreography), and history (autobiography, archaeology). You work alongside them, not above them.
- The BEAM runtime is visible, not hidden. The supervision tree, process health, and message flows are user-facing features that build trust ("I can see what's happening") and provide diagnostics ("the parser is backed up, here's why").
- Time is navigable. You don't just undo; you scrub through history, replay sessions, branch from past states. The editor remembers more than you do.
- The codebase is alive. Health metrics, dependency relationships, and coupling patterns are spatial and visceral, not numbers on a dashboard. You see the code getting sick before the tests fail.
- The environment is aware. The editor adapts to your focus, your typing rhythm, your display, your battery. It's a good citizen of your cognitive and physical context.

Not all of this ships. But every feature we build should move toward this vision, not away from it.
