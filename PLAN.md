# Plan: Generic Picker Framework with Fuzzy Matching

## Goal
Upgrade the existing `Minga.Picker` from a simple substring-matching data structure into a full behaviour-based picker framework with fuzzy/orderless matching, match highlighting, annotations, alternative actions, and a `:picker` mode in the FSM — so that every "pick one from a list" feature (command palette, file finder, buffer switcher, grep, help) is a trivial 10-line wrapper.

## Context

### What exists today
- **`Minga.Picker`** (190 lines) — pure data structure with `{id, label, desc}` items, substring filtering, up/down navigation, visible window scrolling. Solid foundation.
- **Picker rendering** — already implemented in `Editor.do_render/1` via `maybe_render_picker/2`. Bottom-panel overlay with separator, items, prompt line, and cursor positioning.
- **Picker key handling** — `handle_picker_key/3` in `Editor` handles Esc, Enter, C-j/C-k, arrows, backspace, printable chars. Dispatches by `picker_kind` (`:buffer` or `:find_file`).
- **Two picker consumers** — `open_buffer_picker/1` and `open_file_finder/1` in `Editor`, each manually constructing items and handling selection.
- **Editor state** — `EditorState` has `picker`, `picker_kind`, `picker_prev_buffer` fields.
- **No fuzzy matching** — current filtering is `String.contains?` substring match.
- **No match highlighting** — selected items get bold, but matched characters aren't highlighted.
- **No behaviour** — adding a new picker source requires touching `Editor` directly.

### Key patterns
- Modes are atoms (`:normal`, `:insert`, etc.) dispatched via `Mode.process/3`.
- The picker bypasses the Mode FSM — `handle_info` checks `picker != nil` before routing to `handle_picker_key`. This is fine and avoids adding a `:picker` mode to the FSM.
- Rendering uses `Protocol.encode_draw/4+` with fg/bg/bold/reverse options.
- Commands are atoms or tagged tuples executed by `execute_command/2`.

## Approach

Evolve the existing code incrementally rather than rewriting. The picker data structure gets fuzzy matching and scoring. A new `Minga.Picker.Source` behaviour defines the contract for picker sources. The editor's picker handling becomes generic — dispatching select/cancel to the source module rather than branching on `picker_kind`.

### Alternatives Considered
1. **Full `:picker` mode in the FSM** — Issue #16 suggests this, but the current approach (checking `picker != nil` in `handle_info`) is simpler and already works. Adding a mode would require changes to `Mode`, every mode module, and the modeline. Not worth it — the current pattern is fine.
2. **Separate GenServer per picker** — Overengineered. The picker is fast, synchronous, and ephemeral. A data structure in EditorState is correct.
3. **Embark-style action menu (C-o)** — Specified in #16 but premature. We can add it later as a picker-over-actions. Skip for now to keep scope tight.

## Steps

### 1. Add fuzzy/orderless matching to `Minga.Picker`
- **Files**: `lib/minga/picker.ex`, `test/minga/picker_test.exs`
- **Changes**:
  - Replace `refilter/1`'s `String.contains?` with orderless fuzzy matching: split query on spaces, each segment must match independently (case-insensitive). Score candidates by: exact prefix > substring > fuzzy character match. Sort filtered results by score (best first).
  - Add `match_positions/2` function that returns the indices of matched characters in a label, for use by the renderer to highlight them.
  - Keep the existing `filter/2`, `type_char/2`, `backspace/1` API unchanged.
  - Add tests for: orderless matching ("b sw" matches "buffer-switch"), scoring/sort order, `match_positions/2`, edge cases (empty query, all-space query, unicode).

### 2. Define `Minga.Picker.Source` behaviour
- **Files**: `lib/minga/picker/source.ex`
- **Changes**:
  - Define behaviour with callbacks:
    ```elixir
    @callback candidates(term()) :: [Minga.Picker.item()]
    @callback on_select(Minga.Picker.item(), state :: term()) :: term()
    @callback on_cancel(state :: term()) :: term()
    @callback preview?(item()) :: boolean()  # optional, default false
    ```
  - `candidates/1` receives context (e.g., editor state or options).
  - `on_select/2` and `on_cancel/1` receive editor state and return new editor state — this lets each source control what happens.
  - `preview?/1` is optional (default false via `__using__` macro or `@optional_callbacks`).

### 3. Convert buffer picker to a Source
- **Files**: `lib/minga/picker/buffer_source.ex`, `test/minga/picker/buffer_source_test.exs`
- **Changes**:
  - Extract `open_buffer_picker/1`'s item-building logic into `Minga.Picker.BufferSource.candidates/1`.
  - `on_select/2` switches to the selected buffer (extracted from the current `handle_picker_key` Enter clause for `:buffer`).
  - `on_cancel/1` restores the previous buffer.
  - `preview?/1` returns true — buffer picker previews on navigation.

### 4. Convert file finder to a Source
- **Files**: `lib/minga/picker/file_source.ex`, `test/minga/picker/file_source_test.exs`
- **Changes**:
  - Extract `open_file_finder/1`'s item-building logic into `Minga.Picker.FileSource.candidates/1` (delegates to `Minga.FileFind`).
  - `on_select/2` opens the file (extracted from current `:find_file` Enter handler).
  - `on_cancel/1` restores previous buffer.
  - `preview?/1` returns false.

### 5. Generalize Editor picker handling
- **Files**: `lib/minga/editor.ex`, `lib/minga/editor/state.ex`
- **Changes**:
  - Replace `picker_kind` field with `picker_source` (the source module atom) in `EditorState`.
  - Add `open_picker/3` helper: `open_picker(state, source_module, opts)` — calls `source.candidates(opts)`, builds `Picker.new(items, ...)`, stores source module on state.
  - Refactor `handle_picker_key/3`:
    - Enter → calls `state.picker_source.on_select(selected_item, state)`.
    - Escape → calls `state.picker_source.on_cancel(state)`.
    - Navigation (C-j/C-k/arrows) → if source has `preview?` returning true, call `on_select` as preview.
    - Remove `picker_kind`-specific branching.
  - Update `execute_command/2` for `:find_file` and `:buffer_list` to use `open_picker/3`.
  - Remove `picker_kind` and `picker_prev_buffer` from `EditorState` — sources own their own cancel behavior via closure or state stored in the picker's items.

### 6. Add match highlighting to picker rendering
- **Files**: `lib/minga/editor.ex` (in `maybe_render_picker/2`)
- **Changes**:
  - After computing visible items, call `Picker.match_positions/2` for each item's label against the current query.
  - Render matched characters with a highlight color (e.g., `0xE5C07B` yellow) while non-matched characters use the normal text color.
  - This requires splitting each label into segments and issuing multiple `encode_draw` calls per item (similar to how visual selection rendering works).

### 7. Add Command source (bonus — ships command palette, issue #15)
- **Files**: `lib/minga/picker/command_source.ex`, `lib/minga/command/registry.ex` (if not exists), `lib/minga/keymap/defaults.ex`
- **Changes**:
  - Create `Minga.Picker.CommandSource` implementing Source behaviour.
  - `candidates/1` returns all registered commands with their keybinding annotations.
  - `on_select/2` executes the command.
  - Add `SPC :` keybinding in defaults (Doom's `M-x` equivalent).
  - This validates the entire framework end-to-end with a third source.

## Testing
- **Step 1**: Property-based tests for fuzzy matching (any substring of a label always scores > 0; exact match scores highest). Unit tests for orderless matching, `match_positions/2`, scoring sort order.
- **Steps 3-4**: Unit tests for each source's `candidates/1` output shape and `on_select/on_cancel` behavior (using mock editor state).
- **Step 5**: Existing editor integration tests should continue passing. The buffer picker and file finder behavior is unchanged from the user's perspective.
- **Step 6**: Visual — needs manual verification in terminal.
- **Step 7**: Unit test that command source returns all registered commands.
- Run `mix test --warnings-as-errors` after each step.

## Risks & Open Questions
- **Fuzzy scoring algorithm**: Starting simple (orderless substring with prefix bonus). If it feels wrong in practice, can swap in a proper fuzzy scorer (fzy/fzf algorithm) later without changing the API.
- **Performance with large file lists**: The current `Picker.refilter/1` calls `Enum.filter` on every keystroke. For thousands of files this could lag. Mitigation: score+sort is still fast for <10k items; can add debouncing or async filtering later if needed.
- **`picker_prev_buffer` removal**: Moving cancel behavior into sources means each source must capture restore state in its closure. Need to ensure this works cleanly with the GenServer state flow.

## GitHub Ticket

```markdown
# Users can navigate and select from filterable lists throughout the editor

**Type:** Feature

## What
The editor needs a generic picker framework — a single UI component that powers every "choose one from a list" interaction: switching buffers, finding files, running commands, searching, and any future selection-based feature. Currently each picker use case is hardcoded with its own branching logic in the editor.

## Why
This is the highest-leverage infrastructure investment remaining. Once the picker framework exists with a simple behaviour interface, adding new interactive commands (command palette, grep results, help lookup, theme switching) becomes a ~10-line module each. Without it, every new picker feature requires modifying the editor's core key handling and rendering code.

## Acceptance Criteria
- Typing in the picker prompt narrows results using fuzzy/orderless matching (e.g., "b sw" matches "buffer-switch")
- Matched characters are visually highlighted in each candidate
- `Enter` selects the current candidate and performs the source-defined action
- `Esc` cancels and restores previous state
- `C-j`/`C-k` (or arrows) navigate the list; selection wraps at boundaries
- Adding a new picker source requires only implementing a behaviour module — no changes to the editor core
- Buffer switching (`SPC b b`) and file finding (`SPC f f`) continue to work identically from the user's perspective
- A command palette (`SPC :`) is available, listing all registered commands with their keybindings

### Developer Notes
- Evolve the existing `Minga.Picker` data structure — don't rewrite from scratch
- Define `Minga.Picker.Source` behaviour with `candidates/1`, `on_select/2`, `on_cancel/1`
- The picker remains a data structure on `EditorState`, not a separate process or FSM mode
- Fuzzy matching: split query on spaces, each segment matches independently, sort by match quality
- Defer the action menu (`C-o` for alternative actions) to a follow-up ticket
```
