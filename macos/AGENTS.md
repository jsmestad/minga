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
4. **CommandDispatcher** stages commands between `begin_frame` and `commit_frame`, then publishes the committed model atomically. The Metal renderer draws committed window content, and SwiftUI views reactively update from committed `@Observable` state.

### Data flow: user → BEAM

1. **EditorNSView** captures keyboard, mouse, and IME events
2. **SwiftUI views** capture GUI actions (tab clicks, file tree clicks, picker selection, etc.)
3. **ProtocolEncoder** encodes events as binary and writes to stdout
4. The BEAM's **MingaEditor.Frontend.Manager** decodes and dispatches

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

## Directory Layout

Start in `macos/Sources/`: `macos/Sources/Protocol/` owns wire types and codecs, `macos/Sources/Renderer/` owns CoreText and Metal rendering, and `macos/Sources/Font/` owns font loading. Views are grouped under `macos/Sources/Views/Shared/`, `macos/Sources/Views/Editor/`, `macos/Sources/Views/EditorChrome/`, and `macos/Sources/Views/Overlays/`; use the owning surface's State + View pair rather than assuming a flat Views directory. Protocol tests live in `macos/Tests/MingaTests/`, and `macos/project.yml` defines the generated Xcode project.

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

`FrameState` (the renderer's per-frame grid metadata) follows the same rule: **`CommandDispatcher` is the single writer; views only read.** Most `FrameState` fields come straight from protocol opcodes. The one carve-out is the cell-grid dimensions (`cols`/`rows`): they are genuinely view-derived because they depend on the NSView's pixel size and font metrics, which the BEAM cannot know. Even so, the view does not write them directly. View-originated updates funnel through `CommandDispatcher.applyViewportResize(newCols:newRows:)`, and the dirty flag is cleared by `CommandDispatcher.markRendered()` after the view consumes a frame. With one writer, every `FrameState` mutation has one place to add logging, ordering checks, or BEAM coordination, regardless of whether the trigger is a protocol opcode or an AppKit event. The view still sends the `sendReady`/`sendResize` event itself, since that is a view-to-BEAM event, not a state write.

### GUIState is the container, not a god object

`GUIState` holds all sub-states as `let` properties (not a flat bag of fields). Each sub-state is independently observable. Adding a new chrome element means adding one State class, one View, and one `let` property on `GUIState`. No existing code changes.

## Chrome tokens

Use the frontend scales in `Sources/Views/Shared/ChromeTokens.swift` instead of inventing a padding, gap, font size, or corner radius. They describe chrome, not editor cells. They do not read the theme, protocol state, or editor font.

### Spacing

| Token | Points | Intent |
|-------|--------|--------|
| `pixel` | 1 | Optical separation for compact badges and rules. |
| `hairline` | 2 | Badge internals and tight vertical rhythm. |
| `xs` | 4 | Tight inline groups and small control insets. |
| `sm` | 6 | Compact row gaps and vertical control padding. |
| `md` | 8 | Default control gaps and insets. |
| `lg` | 12 | Comfortable rows and panel insets. |
| `xl` | 16 | Separation between groups. |
| `xxl` | 20 | Section padding. |
| `panel` | 24 | Spacious empty-state and dialog insets. |
| `section` | 32 | Major section breaks. |

The 1pt optical and 24pt dialog steps preserve existing chrome, rather than forcing those surfaces onto a different layout. The earlier scale's names changed: old `sm/md/lg/xl/xxl` values map to new `md/lg/xl/xxl/section`. Re-map existing callers by value, not by name.

### Typography

Call `Typography.font(.body, weight: .semibold, design: .monospaced)` when a surface needs an explicit style. `Typography.monospacedSmall` is the shared 11pt, medium-weight, monospaced style for which-key keys, picker candidate labels, and completion labels. Match highlights keep that size and use semibold.

| Step | Points | Intent |
|------|--------|--------|
| `tiny` | 7 | Tiny toolbar disclosure and close glyphs. |
| `symbol` | 8 | Compact chevrons and sync arrows. |
| `micro` | 9 | Status glyphs and small badges. |
| `caption` | 10 | Counts, timestamps, and metadata. |
| `small` | 11 | Dense row labels and key columns. |
| `body` | 12 | Standard chrome text. |
| `emphasis` | 13 | Prompts and primary labels. |
| `title` | 14 | Panel titles and secondary markdown headings. |
| `toolbar` | 15 | Activity-bar symbols and prominent headings. |
| `heading` | 16 | Top-level hover documentation headings. |
| `illustration` | 20 | Empty-state symbols. |
| `action` | 24 | Primary prompt action symbols. |

The symbol and heading extensions preserve existing intentional sizes. Do not shrink an illustration to body text just to pass the guard. Named system text styles such as `.caption` remain available for native adaptive UI. AppKit and custom-font consumers use `Typography.Step.body.rawValue` for the same point scale. Text genuinely derived from runtime metrics goes through `Typography.relative(to:scale:weight:design:)`; it must remain derived, not become a local literal disguised as a runtime value.

### Radius

| Token | Points | Intent |
|-------|--------|--------|
| `accent` | 1 | Narrow active-row accent, not a card. |
| `sm` | 4 | Compact rows, badges, and fields. |
| `md` | 6 | Small panels and controls. |
| `lg` | 8 | Overlays and cards. |
| `xl` | 12 | Large cards and prompt capsules. |

### Source guard and preview evidence

`ChromeTokenGuardrailTests` scans `Sources/Views` for numeric literals anywhere inside balanced `.padding(...)`, `spacing:`, `.font(.system(size:...))`, and `cornerRadius` arguments. Ternaries, arithmetic, and nested wrappers do not bypass it. Metric constants are scanned through complete balanced initializers, including conditional result branches and multiline wrappers. Named `CGFloat` padding/spacing/inset/radius parameters retain their external call labels even when their internal names differ. The only allowed numeric token in guarded arguments is `0`, meaning no spacing. The migration allowlist is empty, and a stale or unexplained entry fails.

`Views/Editor` and `EditorScrollTrack.Metrics` are excluded. `ChromeTokens.swift` is the constant owner, not a consuming view. Frames, row heights, line spacing, editor-cell sizing, and scroll-track geometry keep their own metrics. For runtime layout, retain the arithmetic and replace point-valued offsets with tokens; counts and dimensionless ratios are not spacing steps.

On macOS with the pinned Xcode/XcodeGen and generated protocol sources, run `scripts/preview.sh --all` to capture every name in `PreviewRegistry.swift`. The command creates its ignored snapshot output directory and prints each generated image path; set `PREVIEW_OUTPUT_DIR` to choose another destination. One named preview still works. Extend a scale only with an intent and a before/after preview, rather than adding a literal or a per-view wrapper constant.

The **Chrome preview evidence** workflow builds separate base and proposed checkouts on the same runner. Its artifact contains original before/after PNGs, paged contact sheets, `pixel-change-manifest.json`, and a review summary. The original 45 registry entries are retained; 13 additional fixtures render independent chrome surfaces, a visible canonical workspace header, both timeline representations, and the non-default settings tabs. CI installs the same additional preview definitions, dispatch cases, screenshot sizes, and non-preview target membership exclusions in the base checkout without copying proposed production views. Registry extensions belong only to PreviewHost, alongside their owning registry. `baseline-fixture-supplement.json` records the limited setup. Trigger the workflow through a PR or `gh workflow run chrome-previews.yml --ref <branch> -f base_ref=main`. Pixel differences are review evidence, not a CI pixel gate. A failed real capture fails the workflow; it never substitutes a mock image.

`scripts/chrome_token_migration.json` records each intentional snap by original source line, its reason, derived runtime values, and the representative fixture covering each formerly unpreviewed surface. Registered parent fixtures cover the remaining child views. The pixel manifest reports observed changes separately from source-level candidate tokens. Review every changed preview and investigate any unexplained change before approval. Do not claim a preview is pixel-identical or approved before reading that evidence.

## Adding New Features

### New GUI chrome element (e.g., a new panel or overlay)

1. **Elixir side**: build the semantic model under `lib/minga_editor/render_model/ui/`, encode it under `lib/minga/frontend/adapter/gui/`, then add the opcode to `docs/protocol_schema.toml` and regenerate with `mix protocol.gen`. Follow the root guide's Semantic UI rule, not the legacy protocol parity encoders.
2. **Generated Swift opcodes**: use the generated opcode constant from `macos/.generated/protocol/ProtocolOpcodes.generated.swift`
3. **ProtocolDecoder.swift**: add the `RenderCommand` enum case and decoder
4. **FooState.swift**: create the `@Observable` state class with an `update(...)` and `hide()` method
5. **FooView.swift**: create the SwiftUI view that reads from the state
6. **GUIState.swift**: add `let fooState = FooState()` property
7. **CommandDispatcher.swift**: add the `case .guiFoo` handler that calls `guiState.fooState.update(...)`
8. **Wire it into the view hierarchy** in `MingaApp.swift` or the appropriate container view
9. **Tests**: add encode/decode round-trip test

### New GUI action (user interaction → BEAM)

1. **Schema first**: add the action to `docs/protocol_schema.toml`, then run `mix protocol.gen`
2. **Generated Swift opcodes**: use the generated `GUI_ACTION_FOO` constant from `macos/.generated/protocol/ProtocolOpcodes.generated.swift`
3. **OutboundAction.swift**: add one typed action case. Add a consumer-local closure or enum case to the leaf view that originates it, then translate that value at the composition boundary
4. **ProtocolEncoder.swift**: handle the new case in the exhaustive `send(_:)` encoding path, including an explicit rejection outcome when the payload cannot be encoded
5. **BEAM side**: add decoder clause in `lib/minga_editor/frontend/protocol.ex` and handler in the Editor
6. **SwiftUI view**: emit its consumer-local semantic action. Do not pass `ProtocolEncoder` or the full `OutboundAction` surface into a leaf view

### New render pass or Metal change

1. Modify `CoreTextMetalRenderer.swift` for the draw call
2. If new GPU data types are needed, add structs matching the MSL layout (check `MemoryLayout<T>.stride`)
3. Update `CoreTextShaders.metal` if shader changes are needed
4. Verify alignment: Swift `SIMD3<Float>` is 16-byte aligned to match MSL `float3`

## Protocol Sync

Opcode constants are generated from `docs/protocol_schema.toml`.

- Regenerate with `mix protocol.gen`
- Generated Swift opcodes are written to `macos/.generated/protocol/ProtocolOpcodes.generated.swift`
- `Sources/Protocol/ProtocolConstants.swift` keeps the non-opcode constants
- `lib/minga_editor/frontend/protocol.ex` and `zig/src/protocol.zig` re-export the generated opcode values
- Generated opcode files are ignored build artifacts, not committed source

When adding or changing opcodes, edit the schema and regenerate instead of hand-editing the generated files.

**Common brittleness point:** GUI chrome opcodes encode fields positionally. Adding a field to the middle of an opcode breaks the Swift decoder. Always append new fields at the end. If you need to restructure a message, bump the opcode number and keep the old decoder for backward compatibility during development.

## Tech Requirements

- **Swift 6.0+** with strict concurrency
- **Metal 3.1+** (MSL 3.1), macOS 15.0+ deployment target
- **Xcode 16+** for building
- Install the version pinned in `.xcodegen-version` with `scripts/install_xcodegen` (pass the installation directory as its argument), then build via `xcodegen generate && xcodebuild -project Minga.xcodeproj -scheme Minga build`.

## Coding Standards

### Swift

- **Swift 6 concurrency model.** Use `@MainActor`, `Sendable`, and structured concurrency. No `@preconcurrency` escape hatches unless absolutely necessary. See the "Swift 6 Concurrency Patterns" section below for specific guidance.
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
cd macos
xcodebuild build -scheme Minga -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme Minga -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
```

### Swift 6 Concurrency Patterns

Swift 6 strict concurrency is enforced project-wide. The compiler must be able to prove actor isolation statically. When it can't, you have a design problem, not a compiler limitation.

**Never use `MainActor.assumeIsolated`.** It's a runtime assertion that bypasses the compiler's static checking. If you need it, you've chosen an API that doesn't carry isolation information in its types. Pick a different API.

**NotificationCenter: use async sequences, not callback observers.** The callback-based `addObserver(forName:object:queue:)` returns a `@Sendable` closure. Even with `queue: .main`, Swift 6 can't prove the closure runs on the main actor. Use the async sequence instead:

```swift
// ❌ Bad: callback is @Sendable, can't access @MainActor properties
NotificationCenter.default.addObserver(
    forName: NSScroller.preferredScrollerStyleDidChangeNotification,
    object: nil, queue: .main
) { [weak self] _ in
    self?.handleStyleChange()  // compiler error: main actor-isolated
}

// ✅ Good: @MainActor Task gives the compiler static proof
observerTask = Task { @MainActor [weak self] in
    for await _ in NotificationCenter.default.notifications(
        named: NSScroller.preferredScrollerStyleDidChangeNotification
    ) {
        guard let self else { return }
        self.handleStyleChange()
    }
}
```

Store the `Task` handle and cancel it in `deinit` (or when the observation should stop). The `for await` loop exits naturally when `self` is deallocated via the `weak` capture.

**KVO: use `AsyncStream` or `values(for:)` over `observe(_:options:changeHandler:)`.** Same problem: the KVO change handler is `@Sendable`. Wrap it in a `@MainActor` Task with an `AsyncStream` if needed.

**Timer: use `Task.sleep` in a loop, not `Timer.scheduledTimer`.** The Timer callback has the same `@Sendable` issue. A structured concurrency loop is both safer and easier to cancel:

```swift
blinkTask = Task { @MainActor [weak self] in
    while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard let self else { return }
        self.cursorVisible.toggle()
        self.setNeedsDisplay(self.cursorRect)
    }
}
```

**General rule:** if an API gives you a `@Sendable` closure and you need `@MainActor` access inside it, don't bridge with `assumeIsolated`. Find the structured concurrency equivalent of that API. AppKit and Foundation have async alternatives for nearly everything: `NotificationCenter.notifications(named:)`, `URLSession.data(from:)`, `Task.sleep`, `AsyncStream` for custom event sources.

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
