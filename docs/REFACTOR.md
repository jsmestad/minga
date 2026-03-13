# Editor Architecture Refactor

**Status:** Complete. All planned refactoring work is done.
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

### Phase G: Cleanup and consolidation (PRs #365-#367, #386, #388)
- Stale Surface/Phase comment cleanup
- Legacy "agentic view" naming → "agent split pane"
- Dead AgentView modules deleted (help.ex, mouse.ex: -593 lines)
- Panel insert mode consolidated via agent scope trie (-86 lines)
- **VimState substruct extracted** (PR #386): 8 vim-specific fields (mode, mode_state, reg, marks, last_jump_pos, last_find_char, change_recorder, macro_recorder) moved into `Minga.Editor.VimState`. Creates the CUA (#306) swap boundary.
- Shared `key_sequence_pending?/1` extracted to `Minga.Input` (was duplicated in AgentPanel and FileTreeHandler)
- **EditorState field boundary documented**: `@per_tab_fields` module attribute is the single source of truth for which fields are saved/restored on tab switch. `snapshot_tab_fields/1` and `restore_tab_context/1` derive from it automatically.
