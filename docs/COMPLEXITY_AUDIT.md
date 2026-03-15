# Complexity Audit: Agent Subsystem

**Date:** 2026-03-15
**Triggered by:** Maintainer concern that the codebase is becoming too complicated for Minga's goals.
**Consulted:** Archie (architecture subagent) for independent structural analysis.

## Verdict

The codebase isn't too big for what Minga is. 80K lines for a modal editor with LSP, tree-sitter, an AI agent, and a Zig renderer is reasonable. The problem is concentrated in one subsystem: the agent chat has 3-4 ways to render the same content, and that multiplier ripples into state management, input handling, and commands.

## By the numbers

| Subsystem | Lines | % of codebase |
|-----------|-------|---------------|
| Agent (all agent-related code) | ~19,000 | 24% |
| Editor (non-agent) | ~23,500 | 29% |
| Commands | 7,478 | 9% |
| Buffer | 5,125 | 6% |
| Input handlers | 2,810 | 3% |
| Mode system | 2,729 | 3% |
| Render pipeline | 2,442 | 3% |
| Everything else | ~17,000 | 21% |

The agent subsystem is larger than the buffer subsystem, the mode system, and the entire render pipeline combined. Most of that isn't feature complexity. It's the cost of maintaining parallel rendering paths.

## The root cause: three generations of chat rendering

The agent chat currently renders through three active paths, with PR #608 adding a fourth:

| Path | Module | Lines | When used |
|------|--------|-------|-----------|
| Chrome overlay | `ChatRenderer` | 876 | Side panel |
| Full-screen composite | `View.Renderer` wrapping `ChatRenderer` | 1,360 | Agentic view |
| Content stage 4b | `render_pipeline/content.ex` → `ViewRenderer` | 276 | Window split |
| **PR #608** (buffer pipeline) | `BufferSync` + `ChatDecorations` | ~507 | New, replaces the above |

These are three generations of approach:

1. **Gen 1**: Custom `ChatRenderer` with custom scroll, rendered as a chrome overlay (side panel).
2. **Gen 2**: `ViewRenderer` wrapping `ChatRenderer`, with its own state (`View.State`) for the full-screen layout.
3. **Gen 3**: Buffer pipeline via `BufferSync` + decorations (PR #608).

Gen 3 is clearly the right destination. Once chat messages live in a real buffer with decorations, you get vim motions, tree-sitter highlighting, the standard viewport/scroll system, and the standard render pipeline for free. No custom scroll. No custom draw-tuple generation. No separate state tracking.

But Gen 1 and Gen 2 haven't been removed yet. After PR #608, all four paths coexist.

## How the multiplier shows up

### Two agent state structs with overlapping responsibilities

- `PanelState` (696 lines): scroll, prompt buffer, visibility for the side panel
- `View.State` (368 lines): scroll, focus, preview for full-screen view

Both have `scroll_up/down/to_top/to_bottom`. Both track "how is the agent chat displayed." The only real difference is display mode.

### Input handlers that exist because of custom rendering

- `AgentChatNav` (184 lines): custom scroll/navigation, unnecessary if chat were a standard buffer
- `AgentMouse` (252 lines): hit-testing against custom chat regions
- `AgentPanel` (197 lines): panel-specific input routing
- `AgentSearch` (29 lines): custom search on the custom renderer

### Agent commands split across three files

- `commands/agent.ex` (1,122 lines)
- `commands/agent_sub_states.ex` (473 lines)
- `commands/agent_session.ex` (187 lines)

## What's sound

The core architecture is solid. None of these need rework:

- **Two-process design** (BEAM + Zig): the right call
- **7-stage render pipeline** with typed stage structs: clean
- **Display list IR** (`draw()` tuples, `WindowFrame`, `Frame`): well-designed
- **Window/Viewport/Content model** with tagged unions: extensible
- **Mode FSM** cleanly separated from content
- **NavigableContent protocol** from the Phase A-G refactor: right abstraction
- **`Minga.Scroll`** (generic) vs `Viewport` (buffer-specific): legitimately different
- **Domain boundary credo check**: good instincts about coupling
- **22 input handlers**: small, focused (128 lines avg), the pattern is fine
- **24 command files**: right granularity
- **411 files / 80K lines total**: normal for this scope

## Cleanup path (post-PR #608)

PR #608 does the hard conceptual work of proving the decorations approach works. What remains is deleting the old paths, merging the state, and letting the standard pipeline do its job.

### Step 1: Convert side panel to a window split

The side panel currently renders as a chrome overlay via `ChromeHelpers.render_agent_panel_from_layout` → `ChatRenderer.render()`. Instead, toggling the agent panel should create a window split hosting the `*Agent*` buffer. This is exactly how the file tree already works.

### Step 2: Delete `ChatRenderer`

Its callers are `ChromeHelpers` (eliminated by step 1) and `ViewRenderer` (eliminated by step 3). The `line_message_map` function moves to a line index on `BufferSync` or decoration metadata.

**Expected deletion:** ~876 lines

### Step 3: Simplify `View.Renderer`

Full-screen agentic view becomes: left split with `*Agent*` buffer, right split with preview. `ViewRenderer` shrinks to layout orchestration and preview rendering. Stops producing chat draw tuples entirely.

**Expected reduction:** ~800-1,000 lines

### Step 4: Merge `PanelState` + `View.State` into `Agent.UIState`

One struct with these fields:
- `visible`, `mode` (`:panel | :fullscreen`), `focus` (`:chat | :preview`)
- `prompt_buffer`, `prompt_history`, `history_index`
- `model_name`, `thinking_level`, `provider_name`
- `preview` (Preview.t()), `chat_width_pct`
- `search`, `toast`, `mention_completion`, `pasted_blocks`, `pending_prefix`, `help_visible`

Collapse `EditorState.agent` and `EditorState.agentic` into `EditorState.agent_ui`. Kill `AgentAccess` (one struct, direct access).

**Expected reduction:** ~400-500 lines plus significant cognitive simplification

### Step 5: Audit input handlers

With chat as a standard buffer:
- `AgentChatNav` (184 lines): mostly deletable, standard buffer navigation takes over
- `AgentMouse`: simplifies, buffer clicks work normally
- `AgentSearch`: becomes standard buffer search (`/` in the `*Agent*` buffer)

**Expected reduction:** ~200-300 lines

### Total expected impact

~2,000-3,000 lines deleted from the agent subsystem. One rendering path for chat content. One state struct instead of two. "How does agent chat render?" goes from requiring 6+ modules to understand down to 2: `BufferSync` + `ChatDecorations`.

## What's NOT a problem

These areas look big but are appropriately sized:

- **80K lines total**: Neovim's Lua layer alone is larger.
- **411 files**: directory structure mirrors the domain well, finding things is easy.
- **`buffer_management.ex` at 1,247 lines**: could be split eventually, but isn't confusing.
- **Multiple scroll types**: `Scroll` (generic panels) and `Viewport` (buffer editing) are legitimately different. After the agent cleanup, `View.State`'s manual scroll and `PanelState`'s `Scroll.t()` disappear because the `*Agent*` buffer uses `Viewport` like any other buffer.

## Decision log

| Option | Description | Verdict |
|--------|-------------|---------|
| **A: Complete migration, delete old paths** | Follow through on PR #608's direction | **Recommended** |
| B: Keep multi-path, enforce boundaries | Tidy up but keep three rendering paths | Rejected: each agent feature costs 2-3x forever |
| C: Extract agent as separate OTP app | Clean boundary, own supervision tree | Premature: agent API surface isn't stable yet |

Option A eliminates the root cause (multiple rendering paths for the same content) rather than managing the symptoms. PR #608 already does the hard conceptual work. What remains is following through.
