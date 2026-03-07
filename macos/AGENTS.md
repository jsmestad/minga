# Minga macOS Client — Agent & Developer Guide

## What This Is

A native macOS GUI frontend for the Minga text editor. The BEAM (Elixir) process owns all editor logic: buffers, modes, commands, keymaps. This Swift process is a **renderer and input source only**. It reads binary render commands from stdin, draws them with Metal, and writes keyboard/mouse events back to stdout.

Think of it as a GPU-accelerated terminal emulator that speaks a custom protocol instead of VT100. All intelligence lives in the BEAM. This process is deliberately "dumb."

## Architecture

```
BEAM (parent)                              minga-mac (this process)
─────────────                              ────────────────────────
Port.Manager  ──stdin ({:packet,4})──►  ProtocolReader (background thread)
                                              │
                                              ▼
                                        ProtocolDecoder
                                              │
                                              ▼ (main thread)
                                        CommandDispatcher
                                              │
                                              ▼
                                        CellGrid (in-memory screen state)
                                              │
                                              ▼
                                        MetalRenderer (GPU)
                                              │
                                              ▼
                                        CAMetalLayer (window)

EditorNSView (keyboard/mouse)
      │
      ▼
ProtocolEncoder ──stdout ({:packet,4})──►  Port.Manager
```

The protocol is length-prefixed binary (`{:packet, 4}` framing). Opcodes and field layouts are defined in `lib/minga/port/protocol.ex` on the BEAM side and `Sources/Protocol/ProtocolConstants.swift` here. These must stay in sync.

## Project Structure

```
macos/
  project.yml                          # XcodeGen project definition
  Minga.xcodeproj/                     # Generated Xcode project (do not hand-edit)
  Sources/
    MingaApp.swift                     # App entry point, AppDelegate, SwiftUI wiring
    Protocol/
      ProtocolConstants.swift          # Opcode values, capability constants
      ProtocolDecoder.swift            # Binary → RenderCommand enum
      ProtocolEncoder.swift            # Input events → binary on stdout
      ProtocolReader.swift             # Background thread reading {packet,4} from stdin
    Renderer/
      MetalRenderer.swift              # Two-pass instanced Metal renderer
      Shaders.metal                    # MSL 3.1 vertex/fragment shaders
      CellGrid.swift                   # In-memory cell array with cursor state
      CommandDispatcher.swift          # Routes decoded commands to the CellGrid
    Font/
      FontFace.swift                   # CoreText font loader and glyph rasterizer
      GlyphAtlas.swift                 # Skyline bin-packing texture atlas
    Views/
      EditorView.swift                 # NSViewRepresentable wrapper for SwiftUI
      EditorNSView.swift               # NSView: Metal layer, keyboard, mouse input
  Tests/
    MingaTests/
      ProtocolTests.swift              # Protocol encode/decode round-trip tests
```

## Design Principles

1. **The BEAM is the source of truth.** This process never decides what to display. It renders exactly what the BEAM tells it to render. No local buffer state, no local mode tracking, no local command interpretation.

2. **Cell grid model.** The screen is a grid of cells, just like a terminal. Each cell has a grapheme, fg/bg colors, and attribute flags. The BEAM sends `draw_text` commands with row/col coordinates; we write those into the grid. On `batch_end`, we render the grid to Metal.

3. **Regions for layout.** The BEAM defines rectangular regions (status bar, line numbers, editor pane, which-key popup, etc.) and sets an "active region" before drawing. Draw coordinates are relative to the active region. The CommandDispatcher handles offset and clipping.

4. **No polling, no timers.** Rendering is purely event-driven. We render a frame when the BEAM sends `batch_end`, never on a display-link timer. If the BEAM sends nothing, we draw nothing.

## Tech Requirements

- **Swift 6.0+** with strict concurrency
- **Metal 3.1+** (MSL 3.1), macOS 14.0+ deployment target
- **Xcode 16+** for building
- Build via `xcodebuild -project Minga.xcodeproj -scheme minga-mac build`

## Coding Standards

### Swift

- **Swift 6 concurrency model.** Use `@MainActor`, `Sendable`, and structured concurrency. No `@preconcurrency` escape hatches unless absolutely necessary.
- **camelCase** for all Swift properties and methods. The Metal shader struct field names don't need to match Swift names; only the binary layout matters.
- **SIMD types** for GPU data: `SIMD2<Float>`, `SIMD3<Float>`. These match MSL's `float2`, `float3` alignment (8-byte and 16-byte respectively).
- **No force unwraps** except `Bundle.main.executableURL!` (guaranteed by the OS).
- **`final class`** for non-inheritable classes. Every class in this project should be `final`.
- **`guard` for early returns**, `if let` for happy-path bindings.
- **Doc comments (`///`)** on all public types and methods.

### Metal (MSL 3.1)

- Use modern MSL features: `constant` arrays at module scope, `inline` helper functions.
- `float3` for colors (16-byte aligned). Matches Swift's `SIMD3<Float>`.
- No `discard_fragment()`. Return `float4(0.0)` for transparent fragments. With our premultiplied alpha blend mode this is equivalent, and avoids tile-based deferred rendering penalties on Apple Silicon.
- Doc comments on shader functions explaining what each pass does.

### Protocol Sync

The protocol constants in `Sources/Protocol/ProtocolConstants.swift` must exactly match:
- `lib/minga/port/protocol.ex` (BEAM side, canonical source)
- `zig/src/protocol.zig` (TUI side)

When adding or changing opcodes, update all three files. The BEAM side is the source of truth.

### Testing

- Protocol encode/decode round-trips in `Tests/MingaTests/ProtocolTests.swift`
- Verify struct layout sizes with `MemoryLayout<T>.size` / `.stride` / `.alignment` when changing GPU structs
- `xcodebuild test` must pass

### Pre-build Checks

Before committing Swift changes:

```bash
cd macos && xcodebuild -project Minga.xcodeproj -scheme minga-mac build 2>&1 | tail -5
# Must show BUILD SUCCEEDED
```

## Adding a New Render Command

This requires changes on both the BEAM and Swift sides:

1. **BEAM side** (source of truth): Add opcode constant and encoder in `lib/minga/port/protocol.ex`
2. **Swift constants**: Add the opcode to `Sources/Protocol/ProtocolConstants.swift`
3. **Swift decoder**: Add a case to `decodeCommand()` in `Sources/Protocol/ProtocolDecoder.swift`, add a case to the `RenderCommand` enum
4. **Swift dispatcher**: Handle the new command in `CommandDispatcher.dispatch()`
5. **Tests**: Add round-trip test in `Tests/MingaTests/ProtocolTests.swift`

## Adding a New Input Event

1. **Swift encoder**: Add a `send*()` method to `Sources/Protocol/ProtocolEncoder.swift`
2. **Swift view**: Call the encoder from `EditorNSView` in the appropriate event handler
3. **BEAM side**: Add decoder clause in `lib/minga/port/protocol.ex` and handler in `Port.Manager`

## What This Process Should Never Do

- Parse or interpret text content
- Track editor mode (normal, insert, visual)
- Make decisions about what to display
- Buffer or throttle render commands (let the BEAM control frame pacing)
- Access the filesystem
- Communicate with anything other than the BEAM via stdin/stdout
