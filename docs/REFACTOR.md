# Editor Architecture Refactor

**Status:** Surface layer fully deleted. Agent state on EditorState. Window-level content hosting active.
**Updated:** 2026-03-12

## The One Rule

**The vim editing model applies to all navigable content. Each content type implements `NavigableContent` with the data structure that fits its domain. Don't reimplement navigation commands; implement the protocol instead.**

Minga is agentic-first. The agent view is not a file buffer pretending to be chat. Chat content is structured data (messages, tool calls, code blocks with collapse state, thinking sections). Forcing it into a flat `Buffer.Server` to get vim navigation is the wrong tradeoff: it loses semantic structure, creates streaming/undo problems, and makes interactive elements (approve, collapse) harder.

The shared layer is the **interaction model**, not the data structure:

1. **The editing model (vim/CUA) produces command atoms from key sequences.** `Mode.process(mode, key, mode_state)` returns `:move_down`, `:scroll_half_page`, `:yank`, etc. It doesn't know what content it's operating on.

2. **Each content type interprets those commands against its own data model** via the `NavigableContent` protocol. Same command, different content:
   - File buffer: `:move_down` → `BufferServer.move(buf, :down)` (gap buffer cursor movement)
   - Chat messages: `:move_down` → scroll to next visual line in rendered message list
   - Agent prompt: `:move_down` → `BufferServer.move(prompt_buf, :down)` (this one IS a buffer)

3. **Content-specific actions are domain commands, not editing commands.** Submit prompt, approve tool, reject hunk, toggle collapse, session lifecycle. These belong in domain-specific command handlers, not in the editing model.

### What goes where

| Content | Data structure | Editing | NavigableContent |
|---------|---------------|---------|-----------------|
| File buffer | `Buffer.Server` (gap buffer) | Full vim/CUA (insert, visual, operators, motions) | Buffer adapter |
| Agent prompt | `Buffer.Server` | Full vim/CUA | Buffer adapter |
| Chat messages | Structured list + `*Agent*` Buffer.Server | Navigation only (no insert, no editing) | Buffer adapter (temporary) |
| `*Messages*` buffer | `Buffer.Server` (read-only) | Navigation + yank (no insert) | Buffer adapter |
| Preview/diff pane | Generated read-only content | Navigation + interactive (approve/reject hunks) | Buffer or custom adapter |

## Completed Work

### Phase A-C: Foundations (PR #322)
- NavigableContent protocol + BufferSnapshot adapter
- EditingModel behaviour + Vim adapter
- Window polymorphic content references (`{:buffer, pid}`, `{:agent_chat, pid}`)
- Property-based tests for NavigableContent

### Phase D: Prompt migration (PRs #325, #331, #337, #339)
- Agent prompt backed by Buffer.Server (replacing TextField)
- PanelState accessors replacing direct `panel.input` access
- Input.Vim module deleted (-1,770 lines)

### Phase E: Chat navigation (PRs #344, #346, #351)
- AgentChatNav handler: vim navigation in agent chat via Mode FSM
- TextField deleted (-1,094 lines)
- 17 chat nav tests

### Phase F: Window content + agent state lift (PRs #322, #361, #362, #364)
- Window content polymorphism: `{:agent_chat, pid}` in window tree
- Layout preset system: `:agent_right`, `:agent_bottom`, `:default`
- `toggle_agent_split` command (SPC a a / SPC a v)
- Window-level keymap scope derivation
- Agent state (`agent`, `agentic`) lifted to top-level EditorState fields
- AgentAccess rewritten: direct field access (70 lines, down from 180)
- Agent.Events handles all agent events directly on EditorState
- AgentView surface deleted (460 lines)
- **Entire Surface layer deleted**: behaviour, BufferView, Bridge, Context, SurfaceSync, BufferViewState (-1,416 lines in PR #364)
- Tab contexts store per-tab fields directly as flat maps
- `surface_module` and `surface_state` removed from EditorState

## Remaining Work

### VimState substruct extraction
Extract vim-specific fields (mode, mode_state, reg, marks, last_jump_pos, last_find_char, change_recorder, macro_recorder) from EditorState into a `Minga.Editor.VimState` substruct. This creates the clean boundary for CUA (#306): swap `state.vim` with a different editing model's state struct. Currently these 8 fields are flat on EditorState, touching ~60 call sites.

### Agent panel consolidation
The bottom agent panel (`AgentPanel` handler, 276 lines) and the window-based agent split (`AgentChatNav` handler, 175 lines) coexist as separate input paths. The panel handles prompt input (insert mode keys, arrow keys, @-mention triggers) and chat navigation when the bottom panel is visible. The split pane handles chat navigation via Mode FSM when agent chat is in a window split.

Prompt input should work identically regardless of where the agent UI is displayed (panel or split). Currently the panel has hardcoded Ctrl+D/U for scrolling, Enter for submit, etc. that duplicate what the scope trie and Mode FSM already provide. The consolidation path:
1. Move prompt input handling to a shared module (both panel and split use it)
2. Remove scroll/nav reimplementations from AgentPanel (use AgentChatNav's Mode FSM path)
3. Eventually: bottom panel becomes "just another window position" for the agent split

### EditorState field reduction
EditorState is still large (40+ fields). Some fields are per-tab (saved/restored on tab switch), others are global (theme, port_manager, tab_bar). The per-tab fields could be grouped into a substruct to make the boundary explicit. This is lower priority since the flat map approach works and the Surface overhead is gone.

Agent state (`agent`, `agentic`) is NOT snapshotted per-tab. The Session GenServer is the source of truth for session state (status, messages, pending approval, error). When switching to an agent tab, `EditorState.rebuild_agent_from_session/2` queries the Session process to populate the editor's local agent fields. Background agent events update only `Tab.agent_status` for tab bar rendering; the Session process accumulates the real state independently.
