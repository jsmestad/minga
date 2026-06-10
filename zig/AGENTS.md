# Minga Zig — Agent & Developer Guide

## What This Is

One Zig binary that runs as a BEAM Port process (plus a small one-shot hook-runner helper):

- **minga-parser** — the tree-sitter parsing process. Reads parse/highlight commands from stdin, maintains per-buffer parse trees, writes highlight spans back to stdout. Shared by all frontends (Go TUI, macOS GUI, future GTK4). All grammars are compiled in.

It speaks the same binary protocol as the Swift, Go, and (planned) GTK4 frontends. The BEAM side is the source of truth for all editor state. This process is deliberately "dumb."

> The legacy Zig/libvaxis terminal renderer (`minga-renderer`) was removed in #2223. Zig is now parser infrastructure only; the terminal frontend is the Go/Bubble Tea renderer (`docs/CHARM_TUI.md`). The protocol decoder (`protocol.zig`) still decodes the full schema, including GUI/render opcodes it treats as no-ops, because schema/opcode retirement is tracked separately in #2237.

## Architecture

```
BEAM (parent)                         minga-parser
─────────────                         ─────────────
Parser.Manager ──stdin ({:packet,4})──► parser_main.zig
                                           │
                                           ▼
                                       highlighter.zig (tree-sitter)
                                           │
                                           ▼
                                       protocol.zig (encoder) ──stdout──► Parser.Manager
```

## Project Structure

```
zig/
  build.zig                        # Build configuration (grammars, targets)
  build.zig.zon                    # Package manifest (no external Zig deps)

  src/
    parser_main.zig                # Parser entry point, buffer management, command loop
    protocol.zig                   # Port protocol encoder/decoder
    highlighter.zig                # Tree-sitter highlighter, grammar registration, queries
    query_loader.zig               # Runtime .scm query file loading (~/.config/minga/queries/)
    predicates.zig                 # Tree-sitter predicate evaluation (#match?, #eq?, etc.)
    posix_regex.zig                # POSIX regex wrapper for #match? predicates
    hook_runner_main.zig           # One-shot POSIX process-group helper (minga-hook-runner)
    highlight_bench.zig            # Tree-sitter highlight benchmark

  vendor/grammars/                 # Vendored tree-sitter grammar sources
    {lang}/src/parser.c            # Each grammar has parser.c + optional scanner.c
  src/queries/                     # Embedded highlight queries
    {lang}/highlights.scm          # Per-language highlight capture queries
```

## Build Targets

`build.zig` produces:

- **minga-parser**: `parser_main.zig` → `protocol.zig` + `highlighter.zig` + all grammars. Links ~40 tree-sitter grammar C files and the tree-sitter runtime.
- **minga-hook-runner**: `hook_runner_main.zig` → a small standalone POSIX helper.
- **highlight-bench**: the tree-sitter highlight benchmark used by autoresearch.

The parser links the tree-sitter runtime and all vendored grammar C files. There are no external Zig package dependencies.

## Key Design Patterns

### Protocol sync

Opcode constants are generated from `docs/protocol_schema.toml`.

- Regenerate with `mix protocol.gen`
- `src/protocol.zig` has a generated public export block that re-exports opcode values from `src/generated/protocol_opcodes.zig`; do not edit that block by hand
- Swift opcodes are generated to `macos/.generated/protocol/ProtocolOpcodes.generated.swift`
- BEAM-side protocol modules consume generated opcode values from `.generated/protocol/elixir/lib/minga/protocol/opcodes.ex`
- Generated opcode files are ignored build artifacts, not committed source

When adding or changing opcodes, edit the schema and regenerate instead of hand-editing the generated files.

Direct `cd zig && zig build test` expects `zig/src/generated/protocol_opcodes.zig` and `zig/src/generated/protocol_schema_test.zig` to already exist. Run `mix protocol.gen` first, which also refreshes the generated public opcode export block in `zig/src/protocol.zig`, or use `mix zig.lint` / `mix compile`, which generate them for you.

The parser process handles the parse/highlight commands and parser responses it knows about from the schema. GUI chrome, semantic, and render opcodes are schema-defined and target the frontends; the parser's `protocol.zig` decodes them as no-ops so a shared schema stays consistent. If a new frontend-only opcode can appear on the parser stream, add an explicit decoder skip or no-op handler for it.

## Coding Standards

- **Doc comments (`///`)** on all public functions and types
- **Explicit error handling** — no `catch unreachable` outside tests. Use `try`, return errors, or handle them. If you're `catch`-ing to discard an error, add a comment explaining why.
- **`std.log` for debug output** (routes to stderr or the port protocol). Never write to stdout directly; that's the Port channel.
- **`zig fmt` for all formatting** — no manual style debates. Run before every commit.
- **`mix zig.lint` must pass** — runs `zig fmt --check` + `zig build test`
- **Comptime over runtime** where the type system supports it. Grammar registration happens at comptime.

## Adding a New Tree-Sitter Grammar

1. **Vendor the grammar**: copy the grammar's `src/` directory into `zig/vendor/grammars/{lang}/src/`. You need `parser.c` and optionally `scanner.c`. Add a `VERSION` file with the git tag or commit hash.

2. **Add the highlight query**: place `highlights.scm` at `zig/src/queries/{lang}/highlights.scm`. Start with the grammar repo's query and trim capture names to Minga's supported set: `keyword`, `string`, `comment`, `function`, `type`, `number`, `operator`, `punctuation`, `variable`, `constant`, `property`, `tag`, `attribute`, `namespace`, `label`, `special`.

3. **Register in build.zig**: add a `Grammar` entry to the `grammars` array. Set `has_scanner: true` if the grammar has a `scanner.c`.

4. **Register in highlighter.zig**: add an `extern fn tree_sitter_{lang}()` declaration and an entry in the `languages` array with the grammar function and `@embedFile` for the query.

5. **Register the filetype** (if new): add extension/filename mappings in `lib/minga/language/filetype.ex` on the Elixir side so the BEAM sends the correct language name.

After rebuilding (`zig build` or `mix compile`), the grammar is compiled into the binary. No runtime loading needed. Users can override queries at `~/.config/minga/queries/{lang}/highlights.scm` without recompiling.

## Build and Test

```bash
mix zig.lint              # zig fmt --check + zig build test
mix native.build.support  # Builds the parser + hook runner via the Mix task
cd zig && zig build       # Direct Zig build (faster iteration)
cd zig && zig build test  # Run Zig unit tests only
```

## Logging

The parser routes `std.log` calls through the port protocol to the BEAM. Messages appear in `*Messages*` prefixed with `[PARSER/{level}]`. The parser uses a blocking writer (simple stdin/stdout loop, no event loop), initialized during `main()` before the command loop starts.

**What to log:** startup info, grammar loading, query compilation errors, protocol decode errors.

**What NOT to log:** per-command spam. The parser can process many commands quickly; logging each one would dominate the port channel.

## What This Process Should Never Do

- Parse or interpret text content beyond tree-sitter highlighting (the BEAM owns all editing logic)
- Track editor mode or buffer state beyond per-buffer parse trees
- Make product decisions (parse and highlight exactly what the BEAM sends)
- Communicate with anything other than the BEAM via stdin/stdout
- Access the filesystem (except `query_loader.zig` reading user query overrides)
