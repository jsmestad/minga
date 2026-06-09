# Minga Daily Driver Workstream

This workstream defines the minimum product slice that must become stable enough for Minga to be used as the author’s everyday editor and agent workspace.

## Decision

The daily-driver slice is not "all of Emacs plus all of Claude Code." It is the smallest end-to-end path where one person can open a real project, edit code safely, navigate quickly, run agent tasks, inspect changes, and recover from frontend crashes without losing editor state.

## Non-Goals

- Do not expand this workstream into general editor parity.
- Do not add a new frontend architecture.
- Do not preserve non-semantic frontend rendering paths for compatibility.
- Do not require every experimental shell to reach parity before the traditional editor shell is stable.
- Do not couple agent runtime behavior to one rendering surface.

## Target Experience

- Open Minga from a terminal or native app and attach to a BEAM-owned editor session.
- Open, edit, save, and switch files without corrupting buffers, tabs, cursor state, or undo history.
- Navigate projects with a file tree, picker, search, splits, tabs, and visible status feedback.
- Use language features that matter for daily coding: syntax highlighting, diagnostics display, basic LSP interactions, comments, indentation, and structural navigation where available.
- Run agent tasks against the same editor state without pretending the agent UI is a separate product.
- Recover from frontend crashes or restarts while preserving BEAM-owned buffers and session state.

## Required Lanes

- **Editor Kernel:** buffer correctness, undo/redo, save/load, cursor/motion, search, project navigation, LSP, diagnostics, git state.
- **Agent Runtime:** sessions, tool execution, approvals, filesystem edits, shell execution, change inspection, safety boundaries.
- **Shell Composition:** traditional editor shell first, agentic shell experiments second, shared state underneath both.
- **Semantic UI Contract:** one frontend contract for GUI and terminal clients, with capability flags rather than Swift/Go/GTK identity.
- **Frontend Clients:** Swift/macOS as the polish reference, Go terminal as the semantic terminal frontend, the legacy Zig/libvaxis cell-grid renderer as the current default until Go reaches parity, Zig parser/tree-sitter retained.

## Daily Driver Checklist

- `bin/minga path/to/file` opens a real project reliably.
- File open, edit, save, close, and reopen preserve content and cursor expectations.
- Normal, insert, visual, command, and operator-pending flows are usable for normal editing.
- File tree, picker, status bar, minibuffer, completion, which-key, diagnostics, and git signs render from Semantic UI.
- Agent chat/task execution can read files, propose edits, apply edits, run shell commands, and show tool progress.
- Frontend restart does not lose BEAM-owned editor state.
- Resize, scroll, split, tab, popup, and input handling are stable in the chosen daily-driver frontend.
- Focused validation exists for each daily-driver regression fixed during this workstream.

## Ticket Rules

Every ticket in this workstream must include:

- Lane.
- Non-goals.
- Files to inspect first.
- Files likely modified.
- Acceptance criteria.
- Validation commands.
- Forbidden changes.

Tickets that mix protocol cleanup, terminal renderer work, Zig deletion, and agent shell redesign in one scope should be split before implementation.
