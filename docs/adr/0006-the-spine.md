# ADR-0006: The Spine, a keyboard-first chrome model shared by every frontend

**Status:** Proposed (2026-11-23). Not implemented. The visual reference is the owner's design canvas (https://claude.ai/artifact/4bi2drkwaE9DZjVoPva7rg, private to the owner). The rules themselves live in [`docs/design/`](../design/README.md), which this record governs.

## Decision

Minga's chrome follows one model on macOS and in the terminal, called the Spine:

1. **The text is the interface.** The resting screen is your code, a plain title bar, and one modeline. No icon rail, no permanent sidebar, no tab strip, no workspace container, no key legends on the resting view.
2. **The modeline carries state.** Mode, needs-you, file, change position, git, Minga's state, diagnostics, filetype and position, in that order, with a fixed truncation order. Agent state is one BEAM value rendered the same way everywhere.
3. **`SPC` is the front door.** Discovery happens through the keyboard: pause after a prefix and which-key shows what comes next, with live counts. Every visible action also has a click.
4. **Lists are buffers.** Minga's tasks, the review, diagnostics, the switcher and terminals open as buffers in a bottom drawer or a split. Transient surfaces show their keys; resting surfaces do not.
5. **Vim keys stay Vim in a file.** Minga's changes are handled with leader keys, a text object and ex commands in file buffers. Bare single-letter actions exist only in Minga's special buffers (`*minga-tasks*`, `*minga-review*`).
6. **Undo is yours; Reject is for Minga.** `u` and ⌘Z undo only your own edits. Minga's work leaves through Reject.
7. **Yes and no mean the same thing everywhere Minga asks.** `y` approve or keep, `n` deny or reject, `a` always for this session, `t` this turn, matching today's approval keys.
8. **Two marks carry Minga's identity.** The twist marks where Minga's work is in your text; the orbit and its satellite mark what Minga is doing. Six state words on five shapes (Waiting and Stopped share the hollow dot), always shape plus word.
9. **The terminal UI and the GUI draw the same picture.** A design that cannot be drawn in a terminal with the same layout is probably wrong. Platform-native rendering is welcome; platform-specific interaction models are not.
10. **A terminal is a buffer.** The built-in terminal uses the same modes, marks and yes/no grammar, with command blocks from shell integration.

The detailed rules are in [`principles.md`](../design/principles.md), [`marks.md`](../design/marks.md), [`keys.md`](../design/keys.md), [`surfaces.md`](../design/surfaces.md), [`terminal.md`](../design/terminal.md) and [`tui.md`](../design/tui.md). How we keep both frontends honest is in [`storyboard.md`](../design/storyboard.md).

## Context

Three problems drove this.

**The workspace and agentic views confused people.** Users could not tell the "Agent" workspace from the editor workspace, and behavior that was correct by design read as a bug. A file opened from the Agent workspace stayed in it. The workspace pill said "Idle" while the Agent activity strip said "Errored". Status lived in four places that could disagree.

**The chrome competed for attention.** The top bar carried a workspace capsule, a tab-group glyph, a status dot, a close circle, navigation chevrons, icon-only tabs, split and sync buttons, an agent header with its own status, and a separate activity strip. The footer duplicated toggles from the sidebar. The sidebar was two icons.

**The two frontends drifted.** Each frontend made its own presentation choices, so the same state looked different on macOS and in the terminal, and fixes landed on one side only.

The design went through four rounds on the canvas, with reviews from a Minga UX specialist, a macOS designer and a Doom/Neovim power user. One round moved toward a mouse-first Mac app (a toolbar capsule, popovers of push buttons, an inspector panel). It read as generic and lost the keyboard feel that makes Minga worth switching to, so the Spine keeps Mac polish in the rendering and the keyboard in the interaction model.

## Alternatives rejected

- **Keep workspaces and make them legible.** Every round that kept a container that owns tabs reproduced the "which view am I in" confusion. Conversations, reviews and terminals as buffers remove the question.
- **An IDE layout (activity bar, sidebar panels, tabs).** It reads as a VS Code or Zed reskin and fights a modal, keyboard-first editor.
- **A mouse-first native Mac app.** The toolbar capsule and push-button popovers were reviewed and rejected by the owner as generic. Native conventions are kept where they are native (menu bar, notifications, system accent, text rendering).
- **REVIEW as a mode derived from the cursor that rebinds `y`, `n`, `=`, `Y` in files.** It would turn `yiw` into "keep" and `n` after a search into "reject". Fugitive and gitsigns keep such keys in special buffers for the same reason.
- **Undo as time across authors.** With Minga typing live, `u` would undo Minga's keystrokes out from under you.

## Consequences

- Workspaces, the activity bar, the tab strip, the agent activity strip, the chat header status and duplicated footer toggles go away. Their jobs move to the modeline, which-key, buffers and drawers.
- `SPC a a` changes from "Toggle agent split" to the tasks drawer; the split stays on `SPC a v`. `SPC 1` to `SPC 4` change from tabs to pinned files. Other new keys use bindings that are free today. See [`keys.md`](../design/keys.md).
- The BEAM must say more: ordered modeline segments with priorities, per-author undo groups, task trees with subagents, command blocks for terminals. Frontends decide less: they draw tokens the BEAM sends and drop the lowest-priority segments to fit.
- Design rules become executable: design tokens generated into Swift, Go and Elixir, a scenario registry rendered by both frontends, and flow-graph checks for dead ends. See [`storyboard.md`](../design/storyboard.md).
- Some terminal features need a modern terminal (notifications, the Kitty keyboard protocol, graphics). Each is detected at startup and degrades quietly.

## Open questions

- **Terminal emulator engine.** libvterm, a Go or Swift VT implementation, or libghostty. The Developer Notes on #19 and #122 assume the removed Zig renderer and are stale.
- **Markdown in the conversation.** Rendering Minga's replies with Glamour in Go would duplicate semantics on the frontend. The likely answer is BEAM-styled spans drawn with Lip Gloss and native text.
- **`esc` at the `*minga-shell*` approval prompt.** Does it deny, defer, or leave the request pending with its needs-you state?
- **Key overlaps found while recording this.** `]e` already moves to the next agent edit (`lib/minga/keymap/normal_prefixes.ex:56`); decide whether `]h` replaces it. `]t` is "next class/module" in normal mode (`normal_prefixes.ex:54`), so sibling navigation in the subagent peek split must be scoped to that buffer or use another key.
