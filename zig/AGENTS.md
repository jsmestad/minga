# Minga Zig — Agent & Developer Guide

## What This Is

Two Zig binaries that run as BEAM Port processes:

1. **minga-renderer** — the TUI frontend. Reads render commands from stdin, draws to the terminal via libvaxis, writes keyboard/mouse events back to stdout. Uses `/dev/tty` for terminal I/O (not stdout, which is the Port channel).

2. **minga-parser** — the tree-sitter parsing process. Reads parse/highlight commands from stdin, maintains per-buffer parse trees, writes highlight spans back to stdout. Shared by all frontends (TUI, macOS GUI, future GTK4). All grammars are compiled in.

Both speak the same binary protocol as the Swift and (planned) GTK4 frontends. The BEAM side is the source of truth for all editor state. These processes are deliberately "dumb."

## Architecture

```
BEAM (parent)                         minga-renderer (TUI)
─────────────                         ──────────────────────
Port.Manager  ──stdin ({:packet,4})──►  main.zig (event loop)
                                           │
                                           ▼
                                       protocol.zig (decoder)
                                           │
                                           ▼
                                       renderer.zig (Surface-generic)
                                           │
                                           ▼
                                       apprt/tui.zig (VaxisSurface)
                                           │
                                           ▼
                                       /dev/tty (terminal)

apprt/tui.zig (keyboard/mouse via libvaxis)
      │
      ▼
protocol.zig (encoder) ──stdout ({:packet,4})──►  Port.Manager


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
  build.zig                        # Build configuration (grammars, backends, targets)
  build.zig.zon                    # Package manifest (libvaxis dependency)

  src/
    main.zig                       # Renderer entry point, backend dispatch, panic handler
    parser_main.zig                # Parser entry point, buffer management, command loop
    protocol.zig                   # Port protocol encoder/decoder (shared by both binaries)
    renderer.zig                   # Generic renderer: protocol commands → Surface draw calls
    surface.zig                    # Surface interface (comptime duck typing)
    apprt.zig                      # Backend dispatch (tui, future: gpu)
    apprt/tui.zig                  # TUI backend: libvaxis integration, event loop
    highlighter.zig                # Tree-sitter highlighter, grammar registration, queries
    query_loader.zig               # Runtime .scm query file loading (~/.config/minga/queries/)
    predicates.zig                 # Tree-sitter predicate evaluation (#match?, #eq?, etc.)
    port_writer.zig                # Buffered writer for port protocol output
    recovery.zig                   # Terminal recovery on crash (restores raw mode)
    posix_regex.zig                # POSIX regex wrapper for #match? predicates

    font/
      main.zig                     # Font face abstraction
      atlas.zig                    # Glyph atlas (for future GPU backend)
      coretext.zig                 # CoreText font loader (macOS only)

  vendor/grammars/                 # Vendored tree-sitter grammar sources
    {lang}/src/parser.c            # Each grammar has parser.c + optional scanner.c
  src/queries/                     # Embedded highlight queries
    {lang}/highlights.scm          # Per-language highlight capture queries
```

## Two Binaries, One Codebase

`build.zig` produces two separate executables:

- **minga-renderer**: `main.zig` → `protocol.zig` + `renderer.zig` + `apprt/tui.zig`. Selected via `-Dbackend=tui` (default). Does NOT include `highlighter.zig` or tree-sitter.
- **minga-parser**: `parser_main.zig` → `protocol.zig` + `highlighter.zig` + all grammars. Does NOT include `renderer.zig` or libvaxis.

This separation matters: the parser links ~40 tree-sitter grammar C files. The renderer links libvaxis. Neither needs the other's dependencies.

## Key Design Patterns

### Surface abstraction

`renderer.zig` is generic over a `Surface` type. The Surface interface is enforced at comptime via `surface.zig`:

```zig
pub fn Renderer(comptime SurfaceT: type) type {
    comptime surface_mod.assertSurface(SurfaceT);
    return struct { ... };
}
```

The TUI backend provides `VaxisSurface` (wraps libvaxis). A future GPU backend would provide a `MetalSurface` or similar. The renderer doesn't know which backend it's drawing to.

### Arena-per-frame memory

The renderer uses an arena allocator that resets after every `batch_end`. Grapheme byte slices from protocol messages are copied into the arena so they remain valid until `render()` finishes, then all frame memory is freed in one shot. No per-cell allocation or deallocation.

### Protocol sync

The protocol constants in `src/protocol.zig` must exactly match:
- `lib/minga/frontend/protocol.ex` (BEAM side, canonical source of truth)
- `macos/Sources/Protocol/ProtocolConstants.swift` (macOS side)

When adding or changing opcodes, update all three files. The BEAM side is the source of truth.

The TUI process only handles cell-grid opcodes (0x10-0x1F) and basic commands (clear, cursor, regions, font, batch_end). GUI chrome opcodes (0x70-0x8F) are skipped by the decoder. If you add a new GUI-only opcode, the Zig decoder needs a skip clause (read the byte count and discard) so it doesn't choke on unknown opcodes in a shared protocol stream.

## Coding Standards

- **Doc comments (`///`)** on all public functions and types
- **Explicit error handling** — no `catch unreachable` outside tests. Use `try`, return errors, or handle them. If you're `catch`-ing to discard an error, add a comment explaining why.
- **`std.log` for debug output** (routes to stderr or the port protocol). Never write to stdout directly; that's the Port channel.
- **`zig fmt` for all formatting** — no manual style debates. Run before every commit.
- **`mix zig.lint` must pass** — runs `zig fmt --check` + `zig build test`
- **No allocations in the render hot path** except through the per-frame arena. The render loop must not call `std.heap.page_allocator` or `std.heap.c_allocator` between `clear` and `batch_end`.
- **Comptime over runtime** where the type system supports it. Grammar registration, surface interface validation, and backend dispatch all happen at comptime.

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
mix compile               # Builds both Zig binaries as part of the Mix compile
cd zig && zig build       # Direct Zig build (faster iteration)
cd zig && zig build test  # Run Zig unit tests only
```

## Logging

Both binaries route `std.log` calls through the port protocol to the BEAM. Messages appear in `*Messages*` prefixed with `[ZIG/{level}]` (renderer) or `[PARSER/{level}]` (parser).

The renderer uses a non-blocking port writer (buffered, flushed on batch boundaries). The parser uses a blocking writer (simple stdin/stdout loop, no event loop). Both are initialized during `main()` before the command loop starts.

**What to log:** startup info (terminal size, backend), grammar loading, query compilation errors, protocol decode errors, recovery events.

**What NOT to log:** per-frame or per-cell events. The render loop processes thousands of draw commands per frame; logging any of them would dominate the port channel.

## What These Processes Should Never Do

- Parse or interpret text content (the BEAM owns all editing logic)
- Track editor mode or buffer state
- Make decisions about what to display (render exactly what the BEAM sends)
- Buffer or reorder render commands (process them in order, render on batch_end)
- Communicate with anything other than the BEAM via stdin/stdout
- Access the filesystem (except `query_loader.zig` reading user query overrides)
