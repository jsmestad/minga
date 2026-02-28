# Plan: Vim Motion Parity — Wire Existing + Add Missing Motions

## Goal
Bring Minga's motion system to full Vim/Doom Emacs parity: wire up the existing `Motion` module that's disconnected from the editor, then implement the ~30 missing motions that Vim users rely on constantly (`gg`, `f/F/t/T`, `;/,`, `%`, `{/}`, `H/M/L`, `W/B/E`, `J`, `x`, `r`, `~`, `.`, `>>`, `<<`, search `//?/n/N/*/#`).

## Context

### What exists
- **`Minga.Motion`** — pure functions for `w`, `b`, `e`, `0`, `$`, `^`, `gg`, `G`. All tested. But **never called from Editor** — the `execute_command` clauses for `:word_forward`, `:word_backward`, `:word_end`, `:move_to_first_non_blank`, `:move_to_document_start`, `:move_to_document_end` don't exist.
- **Normal mode** dispatches `w/b/e/$` as command atoms but Editor silently drops them via the catch-all `execute_command(state, _cmd), do: state`.
- **Operator-pending** has motion support for `w/b/e/0/$` as `{:delete_motion, :word_forward}` etc., but Editor has no `execute_command` for `{:delete_motion, _}` or `{:change_motion, _}` or `{:yank_motion, _}` — these also silently drop.
- **Visual mode** dispatches `w/b/e` but same wiring gap.
- **GapBuffer** has `content/1`, `line_at/2`, `offset_to_position/2`, `line_count/1` — sufficient for most motion implementations.

### What's missing entirely
1. **Wiring** — `execute_command` for all existing motion commands
2. **`gg`** — Normal mode doesn't handle the two-key `g` prefix (OP mode does)
3. **`f/F/t/T` + char** — find-char motions (needs intermediate state to capture next char)
4. **`;` / `,`** — repeat last find-char
5. **`%`** — matching bracket jump
6. **`{` / `}`** — paragraph motions
7. **`H/M/L`** — screen-relative motions (need viewport)
8. **`W/B/E`** — WORD motions (whitespace-delimited)
9. **`J`** — join lines
10. **`x`** — delete char at cursor (alias for `dl`)
11. **`r` + char** — replace character
12. **`~`** — toggle case
13. **`.`** — repeat last change (complex — needs change recording)
14. **`>>`/`<<`** — indent/dedent
15. **`/`/`?`/`n`/`N`/`*`/`#`** — search (significant feature, separate issue)
16. **Operator+motion execution** — `d/c/y` + any motion (`dw`, `d$`, `dG`, `cf{char}`, etc.)

### Scoping decision
Search (`/`, `?`, `n`, `N`, `*`, `#`) and repeat (`.`) are large features that warrant their own issues. This plan covers **everything else** — wiring existing motions, new motion functions, operator+motion execution, and single-key editing commands.

## Approach

Three phases:
1. **Wire existing motions** — add `execute_command` clauses to connect Normal/Visual/OP mode dispatches to `Motion` functions via `BufferServer`
2. **Add new motion functions** to `Motion` module + wire them into all three modes
3. **Add single-key editing commands** (`x`, `J`, `r`, `~`, `>>`, `<<`) — these aren't motions but are expected Normal mode keys

The operator+motion system (`dw`, `c$`, `yG` etc.) requires a generic approach: `execute_command` for `{:delete_motion, motion_name}` applies the motion to get a range, then deletes/changes/yanks that range.

## Steps

### 1. Wire existing motions to Editor
- **Files**: `lib/minga/editor.ex`
- **Changes**:
  - Add `execute_command` clauses for: `:word_forward`, `:word_backward`, `:word_end`, `:move_to_first_non_blank`, `:move_to_document_start`, `:move_to_document_end`
  - Each calls the corresponding `Motion` function via buffer content, then `BufferServer.move_to`
  - Pattern: get content + cursor from buffer → call `Motion.xyz(gap_buf, cursor)` → `BufferServer.move_to(buf, new_pos)`

### 2. Wire operator+motion execution
- **Files**: `lib/minga/editor.ex`
- **Changes**:
  - Add generic `execute_command` for `{:delete_motion, motion}`, `{:change_motion, motion}`, `{:yank_motion, motion}`
  - Get cursor + content, apply motion to get target position, determine range (cursor→target), delete/yank that range
  - For `:change_motion`, delete range (editor transitions to insert mode via the OP mode's `:execute_then_transition`)
  - Reuse existing `BufferServer.delete_range/3` and `BufferServer.get_range/3`

### 3. Add `gg` to Normal mode
- **Files**: `lib/minga/mode/normal.ex`, `lib/minga/mode/state.ex`
- **Changes**:
  - Add `:pending_g` field to `Mode.State` (like OP mode already has)
  - `g` → set `pending_g: true`, `gg` → emit `:move_to_document_start`
  - `G` with count → emit `{:goto_line, count}` (Vim's `42G`)
  - Handle `g` prefix for future `ge`, `gE` etc.

### 4. Add `f/F/t/T` find-char motions
- **Files**: `lib/minga/motion.ex`, `lib/minga/mode/normal.ex`, `lib/minga/mode/state.ex`, `lib/minga/editor.ex`, `lib/minga/editor/state.ex`
- **Changes**:
  - Add `Motion.find_char_forward/3`, `find_char_backward/3`, `till_char_forward/3`, `till_char_backward/3`
  - In Normal mode: `f/F/t/T` → set `pending_find: :f | :F | :t | :T` on Mode.State, next char completes the motion
  - Emit `{:find_char, direction, char}` command
  - Editor stores `last_find_char: {direction, char}` on EditorState for `;`/`,` repeat
  - Add to OP mode and Visual mode too

### 5. Add `;` and `,` repeat find-char
- **Files**: `lib/minga/mode/normal.ex`, `lib/minga/editor.ex`
- **Changes**:
  - `;` → emit `:repeat_find_char`, `,` → emit `:repeat_find_char_reverse`
  - Editor looks up `last_find_char` from state and re-applies

### 6. Add `%` matching bracket
- **Files**: `lib/minga/motion.ex`, `lib/minga/mode/normal.ex`, `lib/minga/editor.ex`
- **Changes**:
  - `Motion.match_bracket/2` — find matching `()`, `[]`, `{}` from cursor
  - Scan forward from cursor for first bracket char, then find its match (counting nesting)
  - Wire as `:match_bracket` in Normal, Visual, and OP modes

### 7. Add `{` / `}` paragraph motions
- **Files**: `lib/minga/motion.ex`, `lib/minga/mode/normal.ex`, `lib/minga/editor.ex`
- **Changes**:
  - `Motion.paragraph_forward/2` — move to next blank line
  - `Motion.paragraph_backward/2` — move to previous blank line
  - Wire in Normal, Visual, OP modes

### 8. Add `H/M/L` screen-relative motions
- **Files**: `lib/minga/mode/normal.ex`, `lib/minga/editor.ex`
- **Changes**:
  - These need viewport info, so they emit `{:move_to_screen, :top | :middle | :bottom}`
  - Editor computes target line from viewport and moves cursor
  - Also add to Visual mode

### 9. Add `W/B/E` WORD motions
- **Files**: `lib/minga/motion.ex`, `lib/minga/mode/normal.ex`, `lib/minga/editor.ex`
- **Changes**:
  - `Motion.word_forward_big/2`, `word_backward_big/2`, `word_end_big/2`
  - WORD = whitespace-delimited (non-whitespace runs), vs word = alphanumeric runs
  - Wire in Normal, Visual, OP modes

### 10. Add single-key editing commands
- **Files**: `lib/minga/mode/normal.ex`, `lib/minga/editor.ex`
- **Changes**:
  - `x` → emit `:delete_at` (already exists in editor)
  - `X` → emit `:delete_before` (already exists)
  - `J` → emit `:join_lines` — Editor joins current line with next (delete newline at EOL)
  - `r` + char → `pending_replace: true` in Mode.State, next char → `{:replace_char, char}`. Editor replaces char at cursor.
  - `~` → emit `:toggle_case` — swap case of char at cursor, move right
  - `>>` → emit `:indent_line`, `<<` → emit `:dedent_line` — add/remove leading indent (tab or spaces based on future config, default 2 spaces for now)
  - `+` → emit `:next_line_first_non_blank`, `-` → emit `:prev_line_first_non_blank`

### 11. Update Visual and Operator-Pending modes
- **Files**: `lib/minga/mode/visual.ex`, `lib/minga/mode/operator_pending.ex`
- **Changes**:
  - Add all new motions to both modes: `$`, `^`, `G`, `gg`, `{`, `}`, `H`, `M`, `L`, `W`, `B`, `E`, `f/F/t/T`, `;`, `,`, `%`
  - Visual mode already has `w/b/e` — fix inconsistency: Visual uses `:end_of_word` vs Normal's `:word_end`
  - OP mode already has most motions — add: `^`, `{`, `}`, `H/M/L`, `W/B/E`, `f/F/t/T`, `;`, `,`, `%`

### 12. Tests
- **Files**: `test/minga/motion_test.exs` (expand), new test files as needed
- **Changes**:
  - Test all new `Motion` functions: `find_char_*`, `till_char_*`, `match_bracket`, `paragraph_*`, `word_*_big`
  - Test `execute_command` for operator+motion combos (using headless harness or unit tests)
  - Edge cases: empty buffer, cursor at boundaries, no match for `f/t/%`

## Testing
- Expand existing `test/minga/motion_test.exs` with new motion functions
- Each new motion: test normal case, boundary cases (start/end of line, start/end of buffer), no-match cases
- Operator+motion: test that `dw` deletes a word, `d$` deletes to EOL, `dG` deletes to end, etc.
- Run `mix test --warnings-as-errors` after each step

## Risks & Open Questions
- **`f/F/t/T` state management**: Needs a `pending_find` field on Mode.State + `last_find_char` on EditorState. Two separate state locations — acceptable since one is FSM-transient and one persists across commands.
- **Operator+motion range direction**: When motion goes backward (`db`, `d{`), the range is (target, cursor) not (cursor, target). Need to sort positions.
- **`>>` / `<<` indent size**: Hardcode 2 spaces initially. Will be configurable via issue #24 (per-language settings).
- **Search (`/`, `?`, `n`, `N`, `*`, `#`)** and repeat (`.`) are deferred to separate issues — they're large enough to warrant their own planning.

## GitHub Tickets

### Ticket 1: Wire existing motions and add operator+motion execution

```markdown
# Existing Vim motions execute correctly in the editor

**Type:** Bug

## What
Word motions (`w`, `b`, `e`), line motions (`^`, `gg`, `G`), and operator+motion combos (`dw`, `c$`, `yG`) are bound in the mode FSM but silently do nothing — the editor's command execution layer doesn't handle them.

## Why
Users pressing `w` to jump forward a word, or `dw` to delete a word, get no response. These are among the most basic Vim commands and their absence makes the editor unusable for any real editing task.

## Acceptance Criteria
- `w` moves cursor to start of next word
- `b` moves cursor to start of previous word
- `e` moves cursor to end of current/next word
- `^` moves to first non-blank character on line
- `gg` moves to first line of file
- `G` moves to last line of file
- `dw` deletes from cursor to start of next word
- `d$` deletes from cursor to end of line
- `dG` deletes from cursor to end of file
- `cw` deletes word and enters insert mode
- `yy` yanks current line, `p` pastes it
- All motions work with count prefixes (`3w`, `2dd`)

### Developer Notes
- `Minga.Motion` module already has the pure functions — this is purely a wiring issue
- Add `execute_command` clauses for motion atoms and `{:delete_motion, motion}` tuples
- Sort positions for backward motions before passing to `delete_range`
```

### Ticket 2: Find-char, bracket-match, paragraph, and screen motions

```markdown
# Users can navigate with find-char, bracket-match, paragraph, and screen motions

**Type:** Feature

## What
Vim's mid-frequency navigation motions are missing: `f/F/t/T` (find character on line), `;/,` (repeat find), `%` (matching bracket), `{/}` (paragraph), `H/M/L` (screen position), and `W/B/E` (WORD motions).

## Why
Without these, users are stuck with slow `hjkl` navigation or word-jumping. `f/t` are the fastest way to reach a specific character on a line, `%` is essential for code navigation, and `{/}` is how users move through prose and code blocks. These motions are used hundreds of times per editing session.

## Acceptance Criteria
- `f{char}` moves to next occurrence of char on current line; `F{char}` moves backward
- `t{char}` moves to one before next occurrence; `T{char}` one after previous
- `;` repeats last f/F/t/T in same direction; `,` repeats in reverse direction
- `%` jumps to matching bracket/paren/brace under or after cursor
- `{` moves to previous blank line; `}` moves to next blank line
- `H` moves to top of visible screen; `M` to middle; `L` to bottom
- `W/B/E` navigate by whitespace-delimited WORDs
- All motions work with operators (`df.` deletes to next period, `ct"` changes to next quote, `y}` yanks to end of paragraph)

### Developer Notes
- `f/F/t/T` need a pending-char intermediate state in Mode.State and Mode.OperatorPendingState
- Store `last_find_char` on EditorState for `;/,` repeat
- `H/M/L` emit viewport-relative commands — editor resolves to buffer position
```

### Ticket 3: Single-key editing commands

```markdown
# Users can use single-key editing commands (x, J, r, ~, >>, <<)

**Type:** Feature

## What
Common single-key Vim editing commands are missing: `x` (delete char), `J` (join lines), `r` (replace char), `~` (toggle case), `>>` (indent), `<<` (dedent), `+/-` (next/prev line first non-blank).

## Why
These are the bread-and-butter editing shortcuts that make Vim efficient. `x` to delete a typo, `J` to join lines, `r` to fix a single character, and `>>` to fix indentation are used constantly.

## Acceptance Criteria
- `x` deletes character under cursor; `X` deletes character before cursor
- `J` joins current line with next line (replaces newline with space)
- `r{char}` replaces character under cursor with typed character, stays in normal mode
- `~` toggles case of character under cursor and moves right
- `>>` indents current line by one level; `<<` dedents by one level
- `+` moves to first non-blank of next line; `-` moves to first non-blank of previous line
- All work with count prefixes (`3x` deletes 3 chars, `3J` joins 3 lines, `5>>` indents 5 lines)

### Developer Notes
- `x` can reuse existing `:delete_at` command
- `r` needs pending-char state like `f/F/t/T`
- `>>` / `<<` use 2-space indent initially (configurable later via issue #24)
```
