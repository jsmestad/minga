# Minga — Agent & Developer Guide

## Project Overview

Minga is a BEAM-powered modal text editor with a Zig terminal renderer.
Read `PLAN.md` for full architecture and implementation roadmap.

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
      gap_buffer.ex           # Pure data structure (no GenServer)
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
    keymap.ex                 # Mode-specific keymap management
    keymap/
      trie.ex                 # Prefix tree for key sequences
      defaults.ex             # Default Doom-style keybindings
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

Elixir 1.19's set-theoretic type system catches real bugs at compile time.
Help it by being explicit:

- **`@spec`** on every public function — no exceptions
- **`@type` / `@typep`** for all custom types in every module
- **`@enforce_keys`** on structs for required fields
- **Guards** in function heads where they aid type inference
- **Pattern matching** over `if/cond` — helps type narrowing across clauses
- `mix compile --warnings-as-errors` must pass clean

Example:

```elixir
@type position :: {line :: non_neg_integer(), col :: non_neg_integer()}

@spec move(t(), :left | :right | :up | :down) :: t()
def move(%__MODULE__{} = buffer, direction) when direction in [:left, :right, :up, :down] do
  # ...
end
```

### Elixir Testing

- Test files mirror `lib/` structure: `lib/minga/buffer/gap_buffer.ex` →
  `test/minga/buffer/gap_buffer_test.exs`
- **Descriptive names**: `"deleting at start of line joins with previous line"`
  not `"test delete_before/1"`
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

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`
Scopes: `buffer`, `port`, `editor`, `mode`, `keymap`, `zig`, `cli`

Examples:
- `feat(buffer): implement gap buffer with cursor movement`
- `feat(zig): scaffold libvaxis renderer with port protocol`
- `test(buffer): add property-based tests for insert/delete`

## Port Protocol

BEAM ↔ Zig communication uses length-prefixed binary messages over
stdin/stdout of the Zig process. The Zig process uses `/dev/tty` for
terminal I/O (not stdout).

See `PLAN.md` § "Port Protocol" for the full message specification.

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
