# Snapshot Testing

Minga uses plain-text screen snapshots to catch UI regressions. Each snapshot captures the full terminal screen (text content, cursor position, cursor shape, mode) at a specific point during a test. When the UI changes, the test diffs the current output against the saved baseline and fails if they don't match.

## Quick reference

```bash
# Run snapshot tests
mix test test/minga/integration/

# Update ALL baselines after an intentional UI change
UPDATE_SNAPSHOTS=1 mix test test/minga/integration/

# Update baselines for a single test file
UPDATE_SNAPSHOTS=1 mix test test/minga/integration/command_mode_test.exs

# Update a single test's baseline
UPDATE_SNAPSHOTS=1 mix test test/minga/integration/command_mode_test.exs:42
```

## When to update snapshots

**Update when** the UI intentionally changes:
- Modeline format changed (added a segment, changed spacing)
- Gutter rendering changed (line number format, relative numbers)
- Tilde row style changed
- Tab bar or minibuffer layout changed
- Theme color names changed (snapshots don't capture colors, but cursor shape names appear in metadata)
- New chrome elements added (status indicators, breadcrumbs)

**Don't update when** a test fails unexpectedly. That's the snapshot catching a real bug. Read the diff first.

## Workflow for UI changes

1. Make your UI change in the editor code.
2. Run `mix test test/minga/integration/`. Some snapshot tests will fail.
3. Read each diff carefully. The failure message shows exactly what changed:
   ```
   Diff (- expected, + actual):
     # Cursor: (1, 3) block
     # Mode: normal
     ────────────────────────────────────────
   - 22│ NORMAL  [scratch]        Text  1:1  Top
   + 22│ NORMAL  [scratch]    ●   Text  1:1  Top
   ```
4. If every diff looks correct (matches your intentional change), update the baselines:
   ```bash
   UPDATE_SNAPSHOTS=1 mix test test/minga/integration/
   ```
5. Verify the updated baselines pass: `mix test test/minga/integration/`
6. `git diff test/snapshots/` to review what changed. The diffs should be reviewable in a PR.
7. Commit the updated `.snap` files alongside the code change.

## Snapshot file format

Snapshots live in `test/snapshots/` with paths derived from the test module and snapshot name:

```
test/snapshots/minga/integration/command_mode_test/command_entry.snap
```

Each file is plain text:

```
# Screen: 80x24
# Cursor: (23, 1) beam
# Mode: command
────────────────────────────────────────────────────────────────────────────────
00│ 1: [scratch]
01│ 1 hello world
02│   ~
...
22│ COMMAND  [scratch]                                              Text  1:1  Top
23│:
────────────────────────────────────────────────────────────────────────────────
```

The header has metadata (screen size, cursor position/shape, editor mode). The body has numbered rows showing exactly what appears on screen. These files are designed to be readable in `git diff` and GitHub PR review.

## Writing new snapshot tests

Use `assert_screen_snapshot` from `EditorCase`:

```elixir
defmodule Minga.Integration.MyFeatureTest do
  use Minga.Test.EditorCase, async: true

  test "my feature renders correctly" do
    ctx = start_editor("hello world")

    send_keys(ctx, ":set nu<CR>")

    assert editor_mode(ctx) == :normal
    assert_screen_snapshot(ctx, "my_feature_result")
  end
end
```

The snapshot name must be unique within the module. **Avoid names that differ only by case** (e.g., `insert_a` vs `insert_A`) because macOS has a case-insensitive filesystem and they'll collide.

When you first run a new test, it will fail because no baseline exists. Run with `UPDATE_SNAPSHOTS=1` to create the initial baseline, then verify it looks right before committing.

## When NOT to use snapshots

Some tests depend on external state that varies between runs:

- **File tree tests**: the tree shows real project files, so file counts and names change.
- **Agent panel tests**: agent initialization state varies depending on what's running.
- **File picker**: file counts change as the project evolves.

For these, use targeted assertions (`assert_row_contains`, `screen_contains?`, `assert_modeline_contains`) instead of full-screen snapshots. See `file_tree_test.exs` and `agent_panel_test.exs` for examples.

## Test helpers

All helpers are available via `use Minga.Test.EditorCase`:

| Helper | Purpose |
|--------|---------|
| `start_editor(content)` | Creates a headless editor with the given buffer content |
| `send_keys(ctx, "<Space>bb")` | Sends a vim key sequence, waits for render |
| `send_mouse(ctx, row, col, :left)` | Sends a mouse event, waits for render |
| `send_resize(ctx, width, height)` | Resizes the terminal, returns updated ctx |
| `assert_screen_snapshot(ctx, name)` | Compares or updates the named snapshot |
| `screen_contains?(ctx, text)` | Checks if any screen row contains the text |
| `assert_row_contains(ctx, row, text)` | Asserts a specific row contains text |
| `assert_modeline_contains(ctx, text)` | Asserts the modeline contains text |
| `assert_minibuffer_contains(ctx, text)` | Asserts the minibuffer contains text |
| `screen_text(ctx)` | Returns all rows as a list of strings |
| `screen_row(ctx, n)` | Returns a single row's text |
| `screen_cursor(ctx)` | Returns `{row, col}` of the cursor |
| `buffer_cursor(ctx)` | Returns `{line, col}` of the buffer cursor |
| `editor_mode(ctx)` | Returns the current mode atom |
| `cursor_shape(ctx)` | Returns `:block`, `:beam`, etc. |

## Atomic frame capture

Snapshots are captured atomically at `batch_end` time in the HeadlessPort. The `send_key` function stores the frozen screen state in the test process's memory. This prevents a race where a late async render (e.g., highlight setup) could overwrite the HeadlessPort grid between `send_key` returning and `assert_screen_snapshot` reading it.

If you need to assert on screen state without sending a key first (e.g., immediately after `start_editor`), the macro falls back to reading the live HeadlessPort grid.
