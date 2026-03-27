# Minga macOS Client — Agent & Developer Guide

## What This Is

A native macOS GUI frontend for the Minga text editor. The BEAM (Elixir) process owns all editor logic: buffers, modes, commands, keymaps. This Swift process is a **renderer and input source only**. It receives structured data from the BEAM via a binary protocol on stdin, renders editor content with CoreText + Metal, renders chrome with native SwiftUI views, and writes keyboard/mouse/GUI events back to stdout.

The BEAM is the single source of truth. This process is deliberately "dumb."

## Architecture

```
BEAM (parent)                              Minga macOS (this process)
─────────────                              ────────────────────────────
Port.Manager  ──stdin ({:packet,4})──►  ProtocolReader (background thread)
                                              │
                                              ▼
                                        ProtocolDecoder (binary → RenderCommand enum)
                                              │
                                              ▼ (main thread)
                                        CommandDispatcher
                                        ├──► FrameState (cursor, gutter, grid metadata)
                                        └──► GUIState (SwiftUI @Observable sub-states)
                                              │                    │
                                              ▼                    ▼
                                   CoreTextMetalRenderer     SwiftUI Views
                                   (Metal: bg fills,         (native chrome:
                                    text textures,            tab bar, file tree,
                                    cursors, gutters,         picker, agent chat,
                                    split separators)         status bar, etc.)
                                              │                    │
                                              ▼                    ▼
                                        CAMetalLayer          NSWindow
                                        (editor surface)      (chrome overlays)

EditorNSView (keyboard/mouse/IME)
SwiftUI Views (clicks, text input)
      │
      ▼
ProtocolEncoder ──stdout ({:packet,4})──►  Port.Manager
```

### Data flow: BEAM → screen

1. **ProtocolReader** reads length-prefixed binary messages from stdin on a background thread
2. **ProtocolDecoder** parses bytes into `RenderCommand` enum cases (one enum per opcode)
3. **CommandDispatcher** routes each command: metadata goes to `FrameState`, chrome data goes to `GUIState` sub-states, content goes to `GUIWindowContent`
4. On `batch_end`, the Metal renderer draws using `FrameState` + window content textures, and SwiftUI views reactively update from their `@Observable` state objects

### Data flow: user → BEAM

1. **EditorNSView** captures keyboard, mouse, and IME events
2. **SwiftUI views** capture GUI actions (tab clicks, file tree clicks, picker selection, etc.)
3. **ProtocolEncoder** encodes events as binary and writes to stdout
4. The BEAM's **Port.Manager** decodes and dispatches

## Rendering Pipeline

The renderer uses **CoreText line textures** composited by Metal. This is NOT a cell-grid terminal emulator.

1. The BEAM sends `guiWindowContent` (opcode 0x80) with pre-styled text runs per visible line, one message per editor window per frame
2. **WindowContentRenderer** converts each row's styled runs into `NSAttributedString` → `CTLine` → bitmap textures, cached by content hash in **LineTextureAtlas**
3. **CoreTextMetalRenderer** draws the frame in passes:
   - Background fill quads (one per line, using run bg colors)
   - Block cursor background (before text so text shows on top)
   - Line texture blits (one textured quad per cached line)
   - Gutter fill and separator line
   - Beam/underline cursor overlay (after text)
   - Split separators (vertical and horizontal)
4. Selection highlights, search matches, and diagnostic underlines are overlay quads, not baked into text textures. This means selection changes don't trigger re-rasterization.

## Project Structure

```
macos/
  project.yml                              # XcodeGen project definition
  Minga.xcodeproj/                         # Generated Xcode project (do not hand-edit)
  Sources/
    MingaApp.swift                         # App entry point, AppDelegate, SwiftUI wiring
    BEAMProcessManager.swift               # Spawns and manages the BEAM child process
    Instrumentation.swift                  # Performance timing helpers

    Protocol/
      ProtocolConstants.swift              # Opcode values, capability constants
      ProtocolDecoder.swift                # Binary → RenderCommand enum + all data types
      ProtocolEncoder.swift                # Input/GUI events → binary on stdout
      ProtocolReader.swift                 # Background thread reading {:packet,4} from stdin
      BoardTypes.swift                     # Board card data types
      PortLogger.swift                     # Thread-safe logging to BEAM via protocol

    Renderer/
      CoreTextMetalRenderer.swift          # Multi-pass Metal renderer (bg, text, cursor, gutter)
      CoreTextShaders.metal                # MSL vertex/fragment shaders
      FrameState.swift                     # Per-frame metadata (cursor, gutter, grid dims, theme)
      CommandDispatcher.swift              # Routes decoded commands to FrameState and GUIState
      WindowContent.swift                  # GUIWindowContent data type (0x80 opcode payload)
      WindowContentRenderer.swift          # Styled runs → NSAttributedString → Metal textures
      BitmapRasterizer.swift               # Shared CTLine → CGBitmapContext → MTLTexture
      LineTextureAtlas.swift               # LRU texture cache keyed by content hash
      CachedLineTexture.swift              # Single cached line: texture + metadata
      SlotAllocator.swift                  # Atlas slot management
      PipelineCache.swift                  # Metal pipeline state object cache

    Font/
      FontFace.swift                       # CoreText font loader with fallback chain
      FontManager.swift                    # Font registry (primary + per-ID fonts)

    Views/
      GUIState.swift                       # Container for all @Observable chrome sub-states
      MingaWindow.swift                    # NSWindow subclass
      EditorView.swift                     # NSViewRepresentable wrapper for SwiftUI
      EditorNSView.swift                   # NSView: Metal layer, keyboard, mouse, IME input
      ThemeColors.swift                    # Theme color slots from guiTheme opcode
      ScrollAccumulator.swift              # Smooth trackpad scroll → discrete line events
      TextHighlighting.swift               # Attributed string styling helpers
      IMEComposition.swift                 # Input Method Editor composition state
      BlinkingCursor.swift                 # Cursor blink animation timer

      # Chrome views (each has a *State.swift + *View.swift pair)
      TabBarState.swift / TabBarView.swift
      FileTreeState.swift / FileTreeView.swift / FileTreeHeaderContent.swift
      GitStatusState.swift / GitStatusView.swift / GitStatusHeaderContent.swift
      SidebarContainer.swift / SidebarHeaderButton.swift
      StatusBarView.swift
      PickerState.swift / PickerOverlay.swift
      CompletionState.swift / CompletionOverlay.swift
      WhichKeyState.swift / WhichKeyOverlay.swift
      MinibufferState.swift / MinibufferView.swift
      HoverPopupState.swift / HoverPopupOverlay.swift
      SignatureHelpState.swift / SignatureHelpOverlay.swift
      FloatPopupState.swift / FloatPopupOverlay.swift
      BreadcrumbBar.swift
      AgentChatState.swift / AgentChatView.swift
      BottomPanelState.swift / BottomPanelView.swift
      MessagesContentState.swift / MessagesContentView.swift
      ToolManagerState.swift / ToolManagerView.swift
      Board/BoardState.swift / Board/BoardView.swift
      WorkspaceIconPicker.swift

  Tests/
    MingaTests/
      ProtocolTests.swift                  # Protocol encode/decode round-trip tests
```

## Code Organization Rules

The same layering principles from the top-level AGENTS.md apply here, adapted for the Swift codebase:

### Dependencies flow one way

```
Protocol/  (Layer 0: pure data types, decoding, encoding)
    ↑
Renderer/  (Layer 1: Metal rendering, texture caching, command dispatch)
    ↑
Views/     (Layer 2: SwiftUI views, @Observable state, user interaction)
```

- **Protocol/** modules never import from `Renderer/` or `Views/`. They decode bytes into value types and encode events into bytes. Pure data transformation.
- **Renderer/** modules may use Protocol types (they consume `RenderCommand`, `GUIWindowContent`, etc.) but never import SwiftUI views or `@Observable` state. Exception: `CommandDispatcher` writes to `GUIState` sub-states because it's the bridge between protocol and views.
- **Views/** modules consume `@Observable` state objects and call `ProtocolEncoder` for user actions. They never decode protocol bytes or touch Metal directly.

### State ownership

Each SwiftUI chrome element follows the **State + View** pattern:

- `FooState.swift`: an `@Observable` class that holds the data. Updated by `CommandDispatcher` from protocol opcodes. The State is the **single writer**; views only read.
- `FooView.swift`: a SwiftUI view that reads from the State. Views never mutate state directly; user actions go through `ProtocolEncoder` to the BEAM, which sends back updated state.

This is the "dumb renderer" principle in practice: the view never decides what to show. It renders what the State says. The State never decides what data to hold. It stores what the BEAM sent.

### GUIState is the container, not a god object

`GUIState` holds all sub-states as `let` properties (not a flat bag of fields). Each sub-state is independently observable. Adding a new chrome element means adding one State class, one View, and one `let` property on `GUIState`. No existing code changes.

## Adding New Features

### New GUI chrome element (e.g., a new panel or overlay)

1. **Elixir side**: add the opcode encoder in `lib/minga/frontend/protocol/gui.ex`, add the emit call in `lib/minga/frontend/emit/gui.ex`
2. **ProtocolConstants.swift**: add the opcode constant
3. **ProtocolDecoder.swift**: add the `RenderCommand` enum case and decoder
4. **FooState.swift**: create the `@Observable` state class with an `update(...)` and `hide()` method
5. **FooView.swift**: create the SwiftUI view that reads from the state
6. **GUIState.swift**: add `let fooState = FooState()` property
7. **CommandDispatcher.swift**: add the `case .guiFoo` handler that calls `guiState.fooState.update(...)`
8. **Wire it into the view hierarchy** in `MingaApp.swift` or the appropriate container view
9. **Tests**: add encode/decode round-trip test

### New GUI action (user interaction → BEAM)

1. **ProtocolConstants.swift**: add `GUI_ACTION_FOO` constant
2. **ProtocolEncoder.swift**: add `sendFoo(...)` method to the `InputEncoder` protocol and `ProtocolEncoder` class
3. **BEAM side**: add decoder clause in `lib/minga/frontend/protocol.ex` and handler in the Editor
4. **SwiftUI view**: call `encoder.sendFoo(...)` from the appropriate event handler

### New render pass or Metal change

1. Modify `CoreTextMetalRenderer.swift` for the draw call
2. If new GPU data types are needed, add structs matching the MSL layout (check `MemoryLayout<T>.stride`)
3. Update `CoreTextShaders.metal` if shader changes are needed
4. Verify alignment: Swift `SIMD3<Float>` is 16-byte aligned to match MSL `float3`

## Protocol Sync

The protocol constants in `Sources/Protocol/ProtocolConstants.swift` must exactly match:
- `lib/minga/frontend/protocol.ex` (BEAM side, canonical source of truth)
- `zig/src/protocol.zig` (TUI side)

When adding or changing opcodes, update all three files. The BEAM side is the source of truth.

**Common brittleness point:** GUI chrome opcodes encode fields positionally. Adding a field to the middle of an opcode breaks the Swift decoder. Always append new fields at the end. If you need to restructure a message, bump the opcode number and keep the old decoder for backward compatibility during development.

## Tech Requirements

- **Swift 6.0+** with strict concurrency
- **Metal 3.1+** (MSL 3.1), macOS 15.0+ deployment target
- **Xcode 16+** for building
- Build via XcodeGen: `xcodegen generate && xcodebuild -project Minga.xcodeproj -scheme Minga build`

## Coding Standards

### Swift

- **Swift 6 concurrency model.** Use `@MainActor`, `Sendable`, and structured concurrency. No `@preconcurrency` escape hatches unless absolutely necessary.
- **camelCase** for all Swift properties and methods.
- **No force unwraps** except `Bundle.main.executableURL!` (guaranteed by the OS).
- **`final class`** for non-inheritable classes. Every class in this project should be `final`.
- **`guard` for early returns**, `if let` for happy-path bindings.
- **Doc comments (`///`)** on all public types and methods.
- **SIMD types** for GPU data: `SIMD2<Float>`, `SIMD3<Float>`. These match MSL alignment.

### Metal (MSL 3.1)

- `float3` for colors (16-byte aligned). Matches Swift's `SIMD3<Float>`.
- No `discard_fragment()`. Return `float4(0.0)` for transparent fragments to avoid tile-based deferred rendering penalties on Apple Silicon.
- Doc comments on shader functions explaining what each pass does.

### Testing

```bash
mix swift.build          # Build the macOS app
mix swift.test           # Run protocol round-trip tests
```

## Logging

Use `PortLogger` from anywhere in the Swift codebase. Messages appear in the `*Messages*` buffer prefixed with `[GUI/{level}]`:

```swift
PortLogger.info("Window resized: \(cols)x\(rows) cells")
PortLogger.warn("Glyph atlas full, rebuilding")
PortLogger.error("Metal pipeline creation failed: \(error)")
```

`PortLogger` is thread-safe and silently drops messages before `setup(encoder:)` is called during startup. Use `NSLog` only for errors that happen before the encoder is ready (Metal device init failure, etc.).

**What to log:** startup info (font, cell dims, scale), resize events, errors/warnings, resource lifecycle (atlas rebuilds, pipeline creation).

**What NOT to log:** per-frame or per-keystroke events, raw protocol data, anything that would flood `*Messages*` during normal editing.

## What This Process Should Never Do

- Parse or interpret text content
- Track editor mode (normal, insert, visual)
- Make decisions about what to display
- Buffer or throttle render commands (let the BEAM control frame pacing)
- Access the filesystem (except reading font files)
- Communicate with anything other than the BEAM via stdin/stdout
