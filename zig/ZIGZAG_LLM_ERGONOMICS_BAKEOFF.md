# ZigZag LLM ergonomics bakeoff

Ticket #2190 asks whether agents compose UI changes better with ZigZag-assisted local render computation than with the manual semantic renderer style. The corrected result is stronger than the first writeup: ZigZag is not just a hitbox helper, and it is not limited to below-runtime helpers. It is useful as a Bubble Tea-style terminal framework when the runtime is adapted to Minga’s Port contract.

## Representative change

Change: make retained modeline/status command segments clickable through semantic mouse routing.

Acceptance criteria used for both attempts:

1. A click on a status segment with a non-empty command emits the existing `execute_command` GUI action packet.
2. Non-clickable status segments and editor-body clicks continue to fall back to the raw mouse event path.
3. Right-aligned status segments win overlap because they render after left segments.
4. Command execution stays BEAM-owned. The renderer only maps local terminal coordinates and encodes existing packets.
5. Focused Zig tests cover command packet encoding, modeline hit routing, overlap priority, and fallback miss behavior.

## Attempt A: manual #2181-style renderer

Baseline: throwaway worktree `/tmp/minga-2190-manual-bakeoff` based on `origin/feat-zig-semantic-tui`.

Prompt: implement the representative change without ZigZag `HitBox` or ZigZag helpers.

Outcome: implemented in the throwaway worktree only, not committed and not opened as a PR.

Metrics:

| Metric | Result |
| --- | --- |
| Changed files | 3 (`zig/src/semantic.zig`, `zig/src/protocol.zig`, `zig/src/apprt/tui.zig`) |
| Diff size | 156 insertions, 8 deletions |
| Implementation iterations | 1 code iteration, then formatting/validation |
| Test failures | First `rtk zig build test` failed because generated artifacts were missing; after `mix deps.get` and `mix protocol.gen`, the final build hit an environment disk quota while compiling vendored grammar libs |
| Bug fixes after validation | None needed before the quota failure |
| Review/self-review findings | Raw fallback stayed intact because miss paths returned `null`; packet shape matched BEAM `execute_command`; custom geometry duplicated status rendering rules |

Agent notes:

- The manual implementation was straightforward for this small change, but it mirrored render geometry by hand: status row, left segment spans, right-aligned spans, and right-over-left priority.
- This is exactly the kind of logic that tends to drift when rendering and hit testing evolve separately.
- No in-house widgets were replaced by components. Custom geometry remained for every status segment hitbox.

## Attempt B: ZigZag-assisted current renderer

Baseline: corrected current-renderer stack through #2189, with structural, overlay, hitbox, and runtime adoption moved into their owning PRs.

Prompt: implement semantic mouse routing and runtime/component adoption with ZigZag primitives while preserving BEAM ownership.

Outcome: shipped across PRs #2194 through #2198, then interpreted alongside the corrected component-adoption stack.

Metrics for the representative hitbox change:

| Metric | Result |
| --- | --- |
| Changed files | 5 (`zig/ZIGZAG_HITBOX_NOTES.md`, `zig/src/apprt/tui.zig`, `zig/src/protocol.zig`, `zig/src/semantic.zig`, `zig/src/semantic/hitbox.zig`) |
| Diff size | 244 insertions, 12 deletions |
| Implementation iterations | 1 initial implementation, 1 reviewer fix pass, 1 bug-hunt fix pass |
| Test failures | Initial compile issue while matching ZigZag API in the helper; fixed before final validation |
| Bug fixes after review | Added modeline command routing and fallback coverage after reviewer block; then fixed right-over-left priority and oversized command fallback after bug-hunt |
| Review findings | Final reviewer passed after targeted fixes; bug-hunt passed after overlap and oversized-command fixes |

Agent notes:

- The ZigZag-assisted implementation introduced a reusable `semantic/hitbox.zig` wrapper around `HitBox` and `MouseState` so subsequent surfaces can share terminal row/col mapping.
- The corrected stack uses much more ZigZag than the first bakeoff summary counted: structural chrome uses `TabGroup`, `Tree`, `StatusBar`, and `SplitPane`; overlays use `Help`, `List`, `CommandPalette`, `VirtualList`, `Tooltip`, `Table`, `DataTable`, and `RichLog`; editor-body helpers exercise `Viewport`, `CodeView`, and `renderWithRanges`; hit testing uses `HitBox` and `MouseState`; runtime now uses `zz.Program` with a Minga adapter loop.
- The component-assisted path has a higher first-slice cost than a manual one-off change, but it creates reusable adapter seams and makes the ownership boundary explicit.

## Corrected adoption count

For the representative hitbox change itself:

| Surface/helper | Manual attempt | ZigZag-assisted attempt |
| --- | --- | --- |
| Modeline/status hitboxes | Custom geometry | ZigZag `HitBox` wrapper |
| Mouse interaction metadata | Custom/no shared primitive | ZigZag `MouseState` wrapper available |
| Packet encoding | Existing custom protocol helpers plus new string helper | Existing custom protocol helpers plus new string helper |
| Runtime loop | Custom libvaxis loop | ZigZag `Program` lifecycle plus Minga Port adapter loop |

Across the corrected stack, ZigZag is now adopted or exercised this way:

- Structural chrome: `TabGroup` derives tab presentation state, `Tree` preserves BEAM-owned file-tree row presentation, `StatusBar` derives right-segment layout, and `SplitPane` computes picker preview split geometry.
- Editor body: `Viewport`, `CodeView`, and `renderWithRanges` are exercised in adapter fit checks, while Minga keeps BEAM semantic ownership for spans, selections, diagnostics, scroll-left, and durable editor state.
- Overlays: `Help` renders which-key rows, `List` computes completion rows, `CommandPalette` and `VirtualList` compute picker row/viewport state, `Tooltip` adapts plain hover/signature rows, `Table` adapts tool-manager rows, `DataTable` adapts board rows, and `RichLog` computes agent transcript visible indices.
- Hit testing: local rectangular hitbox mapping goes through ZigZag `HitBox`, with `MouseState` available for local interaction metadata.
- Runtime: ZigZag `Program` owns TTY terminal lifecycle and frame presentation, while Minga’s adapter keeps stdout packet-only and routes stdin semantic packets plus terminal events across the BEAM protocol boundary.

Still custom by design:

- BEAM packet encoding and `port_writer` backpressure.
- Semantic hit action payloads and command execution ownership.
- BEAM ownership of query/filter/focus, selected item state, transcript state, semantic payload meaning, and durable editor state.
- The adapter loop that bridges BEAM stdin/stdout with ZigZag `Program`, because Minga is a Port process and cannot let a terminal framework write to stdout.

## Go/Charm quality bar

A Go/Charm renderer reference is still present (`go/tui`) and documented in `docs/CHARM_TUI.md`. It remains the quality bar for this bakeoff.

Relevant quality-bar observations:

- The Go/Charm renderer opens `/dev/tty` and keeps stdout reserved for BEAM packets.
- Bubble Tea owns terminal presentation and runtime on the TTY.
- It targets Semantic UI, not the legacy cell-grid path.
- It already covers semantic editor rows/spans, tabs/workspaces, status bar/minibuffer, file tree, picker/preview, completion, and which-key overlays.
- It uses components as adapters over decoded semantic state.

The ZigZag path now follows that pattern: terminal framework on the TTY, BEAM packets on stdout, BEAM-owned semantics, and component-backed local presentation adapters.

## Recommendation

Prefer ZigZag as Minga’s Zig terminal framework under the Go/Bubble Tea ownership split.

The original bakeoff result understated ZigZag because it counted only the hitbox slice and assumed runtime ownership was out of scope. The corrected stack changes the result: ZigZag’s value is broader than first-diff size. It provides reusable component seams for chrome, overlays, measurements, hit testing, and terminal presentation, as long as stdout remains packet-only and BEAM-owned semantics remain authoritative.

For #2191, count this as evidence to keep ZigZag seriously: use ZigZag `Program` as the terminal runtime adapter, use ZigZag components where they safely adapt retained semantic payloads, and keep BEAM in charge of editor semantics and commands.
