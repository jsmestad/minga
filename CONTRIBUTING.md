# Contributing to Minga

Thanks for your interest! Minga is in early development and contributions are welcome, whether that's bug reports, feature ideas, or code.

## Build from source

Minga is two programs: an Elixir app (editor logic) and a Zig binary (terminal rendering). You need both toolchains plus Erlang. A version manager makes this painless.

### Install the toolchain

Using [asdf](https://asdf-vm.com/) or [mise](https://mise.jdx.dev/):

```bash
asdf plugin add erlang
asdf plugin add elixir
asdf plugin add zig
```

### Clone and build

```bash
git clone https://github.com/jsmestad/minga.git
cd minga
asdf install          # Installs pinned Erlang, Elixir, Zig from .tool-versions
mix deps.get
mix compile           # Builds both Elixir and Zig
```

The first build takes a few minutes (Zig compiles tree-sitter grammars for 24 languages). After that, rebuilds are incremental and fast.

### Run it

```bash
bin/minga              # Empty buffer
bin/minga path/to/file # Open a file
```

## Running Tests

```bash
mix test                       # Elixir tests
cd zig && zig build test       # Zig renderer tests
```

## Before Committing

All three must pass:

```bash
mix lint                          # Formatting + Credo + compile warnings
mix test --warnings-as-errors     # Tests
mix dialyzer                      # Typespec consistency
```

## Project Layout

See `AGENTS.md` (in the repo root) for the full project structure, coding standards, and conventions. The highlights:

- **`@spec` on every public function**: Elixir 1.19's type system is strict
- **Pattern matching over `if`/`cond`**: multi-clause functions preferred
- **Test files mirror `lib/`**: `lib/minga/buffer/document.ex` → `test/minga/buffer/document_test.exs`
- **Property-based tests** with StreamData for data structures

## Key Documentation

| Doc | What it covers |
|-----|---------------|
| [README.md](README.md) | Project overview and quick start |
| [ROADMAP.md](ROADMAP.md) | Feature grid: what's done, what's planned |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Two-process design, supervision, port protocol |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | Optimization roadmap with BEAM-specific techniques |
| `AGENTS.md` | Coding standards, project structure, how to add features |

## How to Add Things

### A new command
1. Define in `Minga.Command.Registry` with name + description
2. Add keybinding in `Minga.Keymap.Defaults`
3. Implement in the appropriate `lib/minga/editor/commands/*.ex` module
4. Test the command and the keybinding lookup

### A new motion
1. Add function to the appropriate `lib/minga/motion/*.ex` module with `@spec`
2. Wire into `Minga.Mode.Normal` and `Minga.Mode.OperatorPending`
3. Test against known buffer content, including Unicode edge cases

### A new text object
1. Add function to `Minga.TextObject` with `@spec`
2. Register in `Minga.Mode.OperatorPending`
3. Test: cursor inside, cursor outside, nested, empty content

### A new render command (both sides)
1. Add opcode + encoder in `Minga.Port.Protocol`
2. Add decoder + handler in `zig/src/protocol.zig` and `zig/src/renderer.zig`
3. Test encode/decode round-trip on both sides

## Commit Messages

```
type(scope): short description
```

**Types:** `feat`, `fix`, `refactor`, `test`, `docs`, `chore` **Scopes:** `buffer`, `port`, `editor`, `mode`, `keymap`, `zig`, `cli`

Examples:
- `feat(buffer): implement gap buffer with cursor movement`
- `fix(editor): reparse highlights on normal-mode operators`
- `test(buffer): add property-based tests for insert/delete`

## Updating Documentation

When you finish a feature or change the architecture, update:
- **`ROADMAP.md`**: flip status (📋 → 🚧 → ✅), add new rows as needed
- **`docs/ARCHITECTURE.md`**: if you add process types, opcodes, or change supervision
- **`docs/PERFORMANCE.md`**: mark optimizations as done
