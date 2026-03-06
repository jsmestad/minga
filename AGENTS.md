# Minga — Agent & Developer Guide

## Project Overview

Minga is a BEAM-powered modal text editor with a Zig terminal renderer. Read `PLAN.md` for full architecture and implementation roadmap. Read `ROADMAP.md` for the current feature grid and planned work. Read `docs/ARCHITECTURE.md` for the two-process design and its benefits.

## Tech Stack

- **Elixir 1.19** / OTP 28 — editor core (buffers, modes, commands, orchestration)
- **Zig 0.15** with libvaxis — terminal rendering (runs as BEAM Port)
- **ExUnit** + **StreamData** — testing
- Pinned versions in `.tool-versions`

## Project Structure

```
lib/
  minga.ex                    # Root module
  minga/
    application.ex            # OTP application / supervisor tree
    buffer/
      document.ex           # Pure data structure (no GenServer)
      server.ex               # GenServer wrapper for gap buffer
    port/
      protocol.ex             # Port protocol encoder/decoder
      manager.ex              # GenServer managing the Zig Port
    editor.ex                 # Editor orchestration GenServer
    editor/
      viewport.ex             # Viewport scrolling logic
    mode/
      normal.ex               # Vim normal mode
      insert.ex               # Vim insert mode
      visual.ex               # Vim visual mode
      operator_pending.ex     # Operator-pending mode (d, c, y + motion)
      command.ex              # : command mode
    motion.ex                 # Cursor motion functions
    operator.ex               # Operator functions (delete, change, yank)
    text_object.ex            # Text objects (iw, aw, i", etc.)
    command.ex                # Command struct
    command/
      registry.ex             # Named command lookup
      parser.ex               # :command parsing
    comment.ex                 # Line comment toggling per filetype (tree-sitter injection-aware)
    git.ex                     # Git shell utilities (root, show HEAD, stage, blame)
    git/
      buffer.ex              # Per-buffer GenServer: caches HEAD, computes diffs
      diff.ex                # Pure in-memory line diffing via List.myers_difference/2
    config.ex                 # Config DSL (use Minga.Config)
    config/
      options.ex              # Typed option registry with per-filetype overrides
      loader.ex               # Config file discovery and evaluation
      hooks.ex                # Lifecycle hook registry (after_save, after_open, etc.)
      advice.ex               # Before/after command advice (ETS-backed, read_concurrency)
    keymap.ex                 # Mode-specific keymap management
    keymap/
      bindings.ex             # Key sequence to command mappings
      defaults.ex             # Default Doom-style keybindings
      active.ex               # Live merged keymap (defaults + user overrides)
      key_parser.ex           # Human-readable key string parser
    which_key.ex              # Which-key popup logic
    cli.ex                    # CLI entry point
  mix/
    compilers/
      zig.ex                  # Custom Mix compiler for Zig builds

zig/
  build.zig                   # Zig build configuration
  build.zig.zon               # Zig package manifest (libvaxis dep)
  src/
    main.zig                  # Entry point, event loop
    protocol.zig              # Port protocol encoder/decoder
    renderer.zig              # libvaxis render command handler

test/                         # Mirrors lib/ structure
```

## Coding Standards

### Elixir Types (mandatory)

Elixir 1.19's set-theoretic type system catches real bugs at compile time. Help it by being explicit:

- **`@spec`** on every public function — no exceptions
- **`@type` / `@typep`** for all custom types in every module
- **`@enforce_keys`** on structs for required fields
- **Guards** in function heads where they aid type inference
- **Pattern matching** over `if/cond` — helps type narrowing across clauses
- **No `cond` blocks** — use multi-clause functions with pattern matching and guards instead. `cond` defeats BEAM JIT optimizations and hides control flow that the type system and compiler can reason about. Extract a private helper with multiple `defp` clauses rather than inlining a `cond`.
- **`[head | tail]`** over `list ++ [item]` — appending to a list is O(n); prepend and reverse if order matters
- **Bulk text operations** — when inserting or replacing multi-character text in a `Document`, always use bulk operations (`Document.insert_text/2`, `Buffer.Server.apply_text_edit/6`). Never decompose a string into graphemes and reduce over `insert_char` in a loop. Character-by-character insertion is O(n²) on the gap buffer's binary and creates pathological undo stack growth.
- `mix compile --warnings-as-errors` must pass clean

### Pre-commit Checks

All must pass before committing any Elixir changes:

```bash
mix lint                          # Formatting, credo --strict, compile --warnings-as-errors
mix test --warnings-as-errors     # Tests
mix dialyzer                      # Typespec consistency
```

Example:

```elixir
@type position :: {line :: non_neg_integer(), col :: non_neg_integer()}

@spec move(t(), :left | :right | :up | :down) :: t()
def move(%__MODULE__{} = buffer, direction) when direction in [:left, :right, :up, :down] do
  # ...
end
```

### Elixir Testing

- Test files mirror `lib/` structure: `lib/minga/buffer/document.ex` → `test/minga/buffer/document_test.exs`
- **Descriptive names**: `"deleting at start of line joins with previous line"` not `"test delete_before/1"`
- **Property-based tests** with StreamData for data structure modules
- **Edge cases always tested**: empty state, boundaries, unicode
- Run with `mix test --warnings-as-errors`

### Zig

- Doc comments (`///`) on all public functions
- Explicit error handling — no `catch unreachable` outside tests
- `std.log` for debug output (stderr), never stdout (that's the Port channel)
- `zig build test` must pass

### Commit Messages

```
type(scope): short description

Longer body if needed.
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore` Scopes: `buffer`, `port`, `editor`, `mode`, `keymap`, `zig`, `cli`

Examples:
- `feat(buffer): implement gap buffer with cursor movement`
- `feat(zig): scaffold libvaxis renderer with port protocol`
- `test(buffer): add property-based tests for insert/delete`

## Port Protocol

BEAM ↔ Zig communication uses length-prefixed binary messages over stdin/stdout of the Zig process. The Zig process uses `/dev/tty` for terminal I/O (not stdout).

See `PLAN.md` § "Port Protocol" for the full message specification.

## Keeping Documentation Updated

When implementing features, completing planned work, or changing architecture:

- **`ROADMAP.md`** — Update the feature grid status (📋→🚧→✅) when starting or finishing work. Add new rows for features not yet listed.
- **`docs/ARCHITECTURE.md`** — Update when adding new process types, protocol opcodes, or changing supervision structure.
- **`docs/PERFORMANCE.md`** — Mark optimizations as completed when done.

## Adding New Features

### New command
1. Define in `Minga.Command.Registry` with name, description, execute function
2. Add keybinding in `Minga.Keymap.Defaults`
3. Test the command function and the keybinding lookup

### New motion
1. Add function to `Minga.Motion` with `@spec`
2. Register in `Minga.Mode.Normal` and `Minga.Mode.OperatorPending`
3. Test against known buffer content

### New text object
1. Add function to `Minga.TextObject` with `@spec`
2. Register in `Minga.Mode.OperatorPending`
3. Test with edge cases (cursor outside delimiters, nested, empty)

### New render command (requires both sides)
1. Add opcode constant and encoder in `Minga.Port.Protocol`
2. Add decoder and handler in `zig/src/protocol.zig` + `zig/src/renderer.zig`
3. Test encode/decode round-trip on both sides

### New tree-sitter grammar
Adding syntax highlighting for a new language touches four places:

1. **Vendor the grammar** — clone or copy the tree-sitter grammar's `src/` directory into `zig/vendor/grammars/{lang}/src/`. You need `parser.c` and optionally `scanner.c`. Add a `VERSION` file with the grammar version.
2. **Add the highlight query** — place a `highlights.scm` file at `zig/src/queries/{lang}/highlights.scm`. You can start with the query from the grammar's repo and trim capture names to the set Minga supports (keyword, string, comment, function, type, number, operator, punctuation, variable, constant, etc.).
3. **Register in the Zig build** — add a `Grammar` entry to the `grammars` array in `zig/build.zig`. Set `has_scanner: true` if the grammar has a `scanner.c`.
4. **Register in the Zig highlighter** — in `zig/src/highlighter.zig`, add an `extern fn tree_sitter_{lang}()` declaration and an entry in the `languages` array with the grammar function and `@embedFile` for the query.
5. **Register the filetype** (if new) — add extension/filename mappings in `lib/minga/filetype.ex` so the BEAM detects the filetype and sends the correct language name to Zig.

After rebuilding (`zig build` or `mix compile`), the grammar is compiled into the binary and available immediately. No runtime loading needed.

Users can override highlight queries without recompiling by placing `.scm` files at `~/.config/minga/queries/{lang}/highlights.scm`.
