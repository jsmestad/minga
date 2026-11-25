# Charm TUI Renderer

When you run Minga in a terminal, this is the program that draws it. It shows the same tabs, file tree, pickers and agent conversation as the macOS app, because both frontends draw the same description of the screen that the editor core sends them. For you that means the terminal client, the one you use on Linux and over SSH, shows the same surfaces as the desktop app.

This page is for readers who build, debug or change the terminal frontend.

The Charm renderer is the maintained Go/Bubble Tea frontend for Minga's Semantic UI protocol and the only production terminal frontend. Rust remains research, not a promised successor. A replacement requires a separately authorized complete-cutover decision with demonstrated benefit, BEAM protocol/input/presentation conformance, all required surfaces, terminal lifecycle evidence and deletion of the Go implementation. Zig provides parser/tree-sitter infrastructure and the agent-hook process-group helper; its legacy terminal renderer was removed in #2223.

## Build

The normal Mix compile path builds the Go renderer when Go is available:

```bash
mix compile
```

The compiler writes the development binary to `go/tui/bin/minga-renderer-go` and copies the runtime binary to `priv/minga-renderer-go`.

To test only the Go code:

```bash
cd go/tui
go test ./...
```

## Run

Go is the default terminal frontend, so `bin/minga` launches it. Use `bin/minga` (not `mix minga`) so the terminal device is captured correctly for the TUI port:

```bash
bin/minga path/to/file
```

`MingaEditor.Frontend.Manager` launches `priv/minga-renderer-go`. The Go renderer opens `/dev/tty` by default, or `MINGA_TTY` when it is set (the BEAM launch path sets `MINGA_TTY` automatically). `MINGA_FRONTEND` accepts only `go`; any other value (including the removed `zig`) is an error.

## Current Scope

The Charm renderer targets the Semantic UI path, not the legacy cell-grid path. It decodes and renders:

- semantic editor rows and spans
- tab bar and workspace chrome
- status bar and minibuffer
- file tree, including BEAM-gated zero-latency local selection preview for unmodified j/k and Up/Down
- picker, picker preview, completion, and which-key overlays

It renders roughly 9 of the shared-chrome components today. Decoding and rendering the remaining components is tracked in #2100, and overall cross-frontend coverage is tracked in the Semantic UI inventory (#2113).

Keyboard-local presentation follows the committed `gui_focus_owner`, not whichever overlay is visible. `Model.Update` resolves that single fact before preview navigation, preview activation, agent shortcuts, or transcript-key scrolling. Visibility still says whether candidates can be presented; it does not grant them keyboard ownership. Missing or invalid ownership disables local interception and leaves the key routed to the BEAM. A retained preview cannot capture Enter after another surface takes focus.

For example, beginning a normal-mode leader sequence on the launchpad changes the committed owner to the editor's leader FSM while the launchpad stays visible. Down therefore goes to the BEAM without moving the local launchpad highlight. Which-key visibility is only rendering data; it is never a substitute focus gate.

The resident agent transcript owns fixed-size pages, absolute message ordinals, stable local slots and occurrence indexes. A frame prepares only affected entries and validates all transcript, window and gutter commands before one synchronous transcript commit. Removed cells are zeroed and empty pages retired; chrome does not retain consumed transcript payloads. Update and View use this owner serially. The asynchronous Bubble Tea renderer receives the completed `tea.View`, never the mutable transcript.

A wrapped resident pane's committed scroll anchor must match the logical top line and continuation ordinal in its pane geometry. Its visual rank cannot exceed the last full-page origin, `max(totalVisualRows - viewportRows, 0)`. The TUI rejects frames that violate this contract instead of acknowledging a clamped anchor, preserving the last committed state.

The TUI reports its full terminal width and the number of rows below the local header in `ready` and `resize`. Before the first committed frame the title takes one row. Workspaces, tabs, and breadcrumbs can change the header height later; the TUI reports a resize only when the resulting grid dimensions change, even without a terminal resize. Status, minibuffer, and timeline rows stay in the reported grid so the BEAM can reserve them explicitly.

Semantic pane rows, split separators, and surface rectangles count from the first row below the header. The TUI translates those rows for screen composition and applies the inverse to raw pointer events. Native terminal chrome zones still use physical screen coordinates. A terminal too short to draw a body reports at least one grid row for the protocol but does not draw through the header or footer.

## Chrome tokens

A gap that someone counted by hand drifts. One surface puts two spaces between a key and its label, the next puts one, and macOS uses a third value. The TUI therefore spaces its chrome from the same scale as macOS, by the same names, in `go/tui/internal/ui/chrome_tokens.go`. That file is the twin of `macos/Sources/Views/Shared/ChromeTokens.swift` (see [macOS chrome tokens](https://github.com/jsmestad/minga/blob/main/macos/AGENTS.md#chrome-tokens)), and [`docs/design/anatomy.md`](design/anatomy.md) says which token each part of each surface uses.

Polish then becomes a token change. To widen every hint gap, you change one step; you do not search the render files for runs of spaces.

### The scale

Each step stores its macOS point value and converts to cells when it is read, so the conversion lives in one place:

- **Columns** are `floor(points / 8)`, with a minimum of 1 for any step of 4 pt or more. A gap between two pieces of content never vanishes.
- **Rows** are `floor(points / 18)`. A row is the smallest vertical unit, so padding inside a row does not exist in the terminal.

| Go constant | macOS | Columns | Rows |
|---|---|---|---|
| `spacePixel` | 1 pt | 0 | 0 |
| `spaceHairline` | 2 pt | 0 | 0 |
| `spaceXS` | 4 pt | 1 | 0 |
| `spaceSM` | 6 pt | 1 | 0 |
| `spaceMD` | 8 pt | 1 | 0 |
| `spaceLG` | 12 pt | 1 | 0 |
| `spaceXL` | 16 pt | 2 | 0 |
| `spaceXXL` | 20 pt | 2 | 1 |
| `spacePanel` | 24 pt | 3 | 1 |
| `spaceSection` | 32 pt | 4 | 1 |

**What collapses.** `pixel` and `hairline` are zero cells; the TUI draws a glyph or a tint instead. `xs` through `lg` are one column, `xl` and `xxl` are two, and everything up to `xl` is zero rows. The collapse keeps the order of gaps (a key sits closer to its label than one hint sits to the next) without half cells.

Radius steps (`radiusAccent`, `radiusSM`, `radiusMD`, `radiusLG`, `radiusXL`) collapse to two treatments. `accent`, `sm` and `md` are square: a tinted block without a border. `lg` and `xl` are Lip Gloss's rounded border, which `radius.border()` returns. The twelve typography steps (`textTiny` through `textAction`) collapse to a one-cell glyph or one of three treatments: faint (the `text.faint` role), normal and bold. `textStep.style(palette)` returns the treatment with its colour from the palette, never a literal.

### Using it

Never count spaces. Use the helpers:

```go
// Hints xl apart; inside each hint the key sits one column from its word.
hints := strings.Join([]string{"↑↓ move", "Enter choose", "Esc close"}, gap(spaceXL))

// A chip: sm horizontal padding, hairline vertical padding.
chip := lipgloss.NewStyle().Padding(padding(spaceHairline, spaceSM)).Render(key)

// A fill computed from measured widths is layout arithmetic, not spacing.
fill := strings.Repeat(" ", max(width-lipgloss.Width(left)-lipgloss.Width(right), 0))
```

A width budget is the outer width minus what is drawn beside the text, measured or named, never counted. Measure the lead you drew (`width-lipgloss.Width(lead)`) or name the step it came from (`width-spaceXL.cols()`). A bordered popup goes further: it renders through a `popupFrame` (`m.popoverFrame()` for the picker and the notification center, `m.whichKeyFrame()` for which-key), and takes its content budget from the same frame with `frame.contentWidth(outer)` and `frame.contentHeight(outer)`. The budget then follows the border and the inset tokens, so raising an inset cannot make fitted rows wrap.

```go
frame := m.popoverFrame()
contentWidth := frame.contentWidth(popupWidth) // popupWidth minus the border and popoverRowInset on each side
return frame.render(popupWidth, strings.Join(rowsFittedTo(contentWidth), "\n"))
```

When a surface has a part in `anatomy.md`, use the part metric instead of a raw step. Part metrics live in the same file, one block per part, named by part: `listRowTitleToMeta`, `whichKeyColumnGap`, `modelineSegmentGap`, `promptLabelToQuery`, `decisionBarRows`, and so on. A surface whose anatomy part has not landed yet uses the step that keeps its current cells, or an interim metric such as `agentTranscriptInset`, until its own ticket reshapes it.

### The guard

`chrome_token_guardrail_test.go` is the twin of `ChromeTokenGuardrailTests` on macOS. It parses every non-test Go file in `internal/ui` and fails on:

- an integer literal other than `0` anywhere in the arguments of a Lip Gloss `Padding*`, `Margin*`, `Width`, `Height`, `MaxWidth` or `MaxHeight` call, including nested calls and arithmetic offsets;
- the same literal in the width argument of `fit`, `renderPadded`, `firstCompactLine`, `ansi.Truncate`, `ansi.TruncateWc`, `ansi.Wrap` or `lipgloss.PlaceHorizontal`;
- `strings.Repeat(s, n)` when `s` is a string literal of spaces, in any quoting (`" "`, a raw-string space, `"\x20"`), and `n` is a literal or a literal added to or subtracted from a value;
- a string literal with two or more consecutive spaces.

Layout arithmetic passes: a literal that is a direct argument of a `min` or `max` clamp (`max(width, 1)`), an operand of `*` or `/` (`available/2`), or an index. A literal offset such as `width-3` fails; give it a name from the scale or measure what it stands for.

The guard reads call shapes, not data flow. It does not check a budget computed into a local variable before the call (`wrapWidth := width-3` followed by `ansi.Wrap(text, wrapWidth, "")`), a padding width in a `fmt.Sprintf` verb (`%-4s`, `%*s`), a run of spaces built by concatenating single spaces or repeating a variable string, or a Lip Gloss method called through a method value. Review those shapes by hand; the frame grids below catch the cells they produce. `chrome_tokens.go` owns the constants and is not scanned. The test keeps a fixed list of excluded editor-cell files, each with a reason; it is empty today because editor-cell code in this package names its cell widths (`gutterSignCells`, `scrollbarCells`). The migration allowlist is empty, and a stale or unexplained entry fails.

`chrome_tokens_test.go` asserts each step's columns and rows, each part metric against the TUI column of `anatomy.md`, and parity with `ChromeTokens.swift`: it fails when a step exists on one frontend only, when the two disagree about its points, or when a `static let`, `static var` or `case` line in the Swift `Spacing`, `Radius` or `Typography.Step` body is written in a form the parity parser does not read (a trailing comment, a `Double` type, two cases on one line). `TestChromeTokenFrames` renders every chrome surface at 80x24 and 120x40 and compares each 80x24 grid with its committed golden in `go/tui/internal/ui/testdata/chrome_token_frames/`, so a character that moves fails the test. After an intentional change, rewrite the goldens with `go test ./internal/ui/ -run TestChromeTokenFrames -update`, review the diff, and record the change in `go/tui/chrome_token_migration.json`. Set `MINGA_TUI_FRAME_DIR` to also write the 120x40 grids for a before and after diff. `TestPopupFrameBudgetFollowsEveryInsetStep` raises each popup inset to every step of the scale and shows that fitted rows never wrap.

### Extending the scale

1. Change `docs/design/anatomy.md` first: the token or part, with its intent.
2. Change `ChromeTokens.swift` and `chrome_tokens.go` in the same pull request. The parity test fails if only one side moves.
3. Add or update the part metric and its row in `TestChromeTokenPartMetricsMatchAnatomy`, then record the frames that changed.

## Editor pointer input

The TUI resolves text clicks and drags from the committed row store, terminal grapheme widths, clipping, and local scroll transform used to render the editor. It sends `editor_text_event` with the presentation ID, absolute row-store rank, row ID, and composed UTF-16 offset. The renderer maps that position to source bytes; the BEAM owns selection and editing behavior.

The input model activates the final committed text presentation for each Bubble Tea update and discards presentations it can no longer use. These lifecycle messages stay ordered with pointer input. Drag capture stays with the originating editor pane until release, including release after a stale or missing target. Chrome and overlays retain their input precedence. See [the input ownership contract](ARCHITECTURE.md#the-input-rule) and [the wire format](PROTOCOL.md#0x1e-editor_text_event).

The Agent composer keeps Send, Steer, Queue Next, and Stop in fixed positions while a turn runs. The composer is a Vim buffer: Enter adds a newline in Insert and sends from Normal mode, where sending steers an active turn. Alt+Enter in Insert queues a follow-up during an active turn. The buttons take their hit cells and targets from the last view Bubble Tea flushed, not from an editor frame the terminal has not displayed. If a terminal write is active at pointer admission or begins before the click's target is selected, the TUI drops that left press instead of guessing which view it hit. Keyboard input, wheel input, and mouse releases are unaffected.

Use **Queue** in the Agent header or `SPC a q q` to inspect the current conversation's pending inputs. Select a row to review it, then choose **Withdraw queued input** to remove that entry. The composer and other entries do not change. If the turn consumed the entry before confirmation, open the queue again to see what is still pending.

A finite wheel burst must finish without another input event. The input filter forwards each normalized wheel event to `Model.Update` with its coordinates and modifiers intact; the model reads the signed delta from that event, not shared filter state. The filter never holds wheel input for a later event. Pointer motion remains rate-limited.

## Capture actual terminal output

Use the production capture when a renderer change looks correct in a model test but leaves stale cells or loses updates in a terminal. `scripts/go_tui_capture.py` launches the supplied production binary with a real PTY, sends committed protocol frames through separate pipes, and reconstructs the emitted ANSI stream into terminal cells. It does not call `Model.View` in place of running the renderer.

You need the pinned Elixir/OTP and Go toolchains, Python 3 with `venv`, and network access for the one-time decoder installation. Run this from the repository root:

```bash
capture_root="$(mktemp -d /tmp/minga-go-capture.XXXXXX)"
capture_root="$(realpath "$capture_root")"
python3 -m venv "$capture_root/venv"
"$capture_root/venv/bin/python" -m pip install -r scripts/go_tui_capture_requirements.txt
mix run --no-start scripts/go_tui_capture_corpus.exs --check
go_bin="$(go env GOROOT)/bin"
"$go_bin/go" -C go/tui build -mod=readonly -trimpath '-ldflags=-s -w' -o ../../priv/minga-renderer-go ./cmd/minga-renderer-go
mkdir -p "$capture_root/home" "$capture_root/config" "$capture_root/data" "$capture_root/cache" "$capture_root/tmp"
env HOME="$capture_root/home" XDG_CONFIG_HOME="$capture_root/config" XDG_DATA_HOME="$capture_root/data" XDG_CACHE_HOME="$capture_root/cache" TMPDIR="$capture_root/tmp" PATH="$go_bin:$PATH" "$capture_root/venv/bin/python" scripts/go_tui_capture.py --binary priv/minga-renderer-go --corpus test/fixtures/go_tui_capture/agent_workspace.json --output "$capture_root/artifacts"
```

The explicit build matters: the capture records the supplied binary's hash, not an assertion that an existing binary matches the checkout. Build metadata and the separate capture-checkout context let a reviewer distinguish those facts. The private HOME/XDG roots keep the renderer run away from normal configuration and data.

The checked-in corpus uses canonical Elixir encoders and the astrodark theme at 60×24, 80×24 and 140×40. Each size captures a transcript with user and assistant messages, a completed tool result, an approval prompt, a composer and a status bar. Later committed frames replace one row through `0xA2` while retaining its neighbors, skip a framed unknown opcode before a known visible update, and replace the workspace without retaining old labels.

Inspect every size's `.txt` or `.grid.json` files, not just the exit code. The run directory also retains raw terminal/protocol/input/stderr streams, the corpus, byte offsets and `metadata.json`. A timeout, partial grid, stale label, crash, unsuccessful or forced shutdown, or byte-limit failure exits nonzero and retains diagnostics. A forced shutdown fails even if the renderer's signal handler returns zero. Default bounds are five seconds per step, a sixty-second read/wall deadline, 32 MiB of artifacts and five retained owned runs. Use a dedicated artifact root. The driver rejects symlinked paths and only prunes marked run directories; it leaves unrelated entries untouched.

To update the corpus after an intentional semantic change, run `mix run --no-start scripts/go_tui_capture_corpus.exs`, review the new committed frames and expectations, then run the check and actual capture again. Do not weaken an expectation to accept unexplained terminal residue. The optional developer tests run with `"$capture_root/venv/bin/python" test/scripts/go_tui_capture_test.py`; they cover emulator boundaries and failure handling, not production visual acceptance.

This evidence is an emitted-text-cell capture, not pixel, color, animation or live-interaction proof. The ready-only `scripts/go_tui_boot_smoke.py`, model-only coverage tracked in #2101 and legacy Zig snapshots prove different contracts. Production capture gates Go UI acceptance, not the start of a focused repair. A user-facing change still needs its actual keyboard and mouse walkthrough, plus the relevant [screen snapshot review](https://github.com/jsmestad/minga/blob/main/docs/recipes/update-snapshots.md).

## Storyboard frames

`internal/ui/storyboard_render_test.go` draws every built storyboard scenario from the packets the BEAM recorded for it, through `port.DecodePacket` and `Model.Update`, and writes each frame as a text grid with its style runs. It runs only when `MINGA_STORYBOARD_TRANSCRIPTS` is set; `design/tools/storyboard/renders.py render` sets it. The frames are the TUI baselines in `test/storyboard/baselines/`; see [Renders and baselines](design/storyboard.md#renders-and-baselines). Next to each frame it writes `*.parts.json`: the anatomy parts `storyboard_parts_test.go` finds in the drawn cells by the text the semantic model gave them (the which-key panel, its keys and labels, the modeline segments), which the [layout audit](design/anatomy.md#the-layout-audit) measures.

## Time Agent opening in the packaged terminal editor

Use the shipping launcher to measure what a user waits for after pressing `SPC a n`. The renderer boot smoke cannot measure this request because it does not start the BEAM or send keys. From the source checkout, run:

```bash
timing_root="$(mktemp -d)"
python3 -m venv "$timing_root/venv"
"$timing_root/venv/bin/python" -m pip install -r scripts/go_tui_capture_requirements.txt
"$timing_root/venv/bin/python" scripts/journey_agent_open.py \
  --launcher _build/prod/rel/minga/launchers/minga \
  --revision "$(git rev-parse HEAD)" --output "$timing_root/evidence"
```

Point `--launcher` to the assembled release's launcher (or `Minga.app/Contents/Resources/bin/minga-tui`) and supply the commit that built those bytes, not an unrelated source checkout. The non-gating **Shipping Agent-open timing** workflow uses the pinned release toolchain and uploads the same evidence without publishing a package.

The driver starts a new disposable profile for every pair, opens a known file, and sends the cold keys on the first visible editor frame. After the first configured conversation settles, it returns to the file and repeats the keys in the same VM. Each timing ends at the first PTY read containing the complete editable composer, which can precede provider readiness. `samples.ndjson` records input and read timestamps; `summary.json` reports nearest-rank p50 and p95 separately from at least 20 cold and 20 warm samples. If the composer never appears, the run fails and keeps the last screen and terminal stream rather than counting a timeout as a sample.

The disposable profile supplies a synthetic OpenAI credential so the built-in Native provider resolves a default model through the packaged local catalog. The driver never submits a prompt and does not qualify remote inference. It measures the Go TUI and the shared Editor. Native macOS adds AppKit key delivery, SwiftUI layout and display presentation, none of which this number includes.

## Validation

Before pushing renderer changes, run:

```bash
cd go/tui && go test ./...
mix compile --warnings-as-errors
mix protocol.gen --check
```
