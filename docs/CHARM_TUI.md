# Charm TUI Renderer

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

## Editor pointer input

The TUI resolves text clicks and drags from the committed row store, terminal grapheme widths, clipping, and local scroll transform used to render the editor. It sends `editor_text_event` with the presentation ID, absolute row-store rank, row ID, and composed UTF-16 offset. The renderer maps that position to source bytes; the BEAM owns selection and editing behavior.

The input model activates the final committed text presentation for each Bubble Tea update and discards presentations it can no longer use. These lifecycle messages stay ordered with pointer input. Drag capture stays with the originating editor pane until release, including release after a stale or missing target. Chrome and overlays retain their input precedence. See [the input ownership contract](ARCHITECTURE.md#the-input-rule) and [the wire format](PROTOCOL.md#0x1e-editor_text_event).

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

This evidence is an emitted-text-cell capture, not pixel, color, animation or live-interaction proof. The ready-only `scripts/go_tui_boot_smoke.py`, model-only coverage tracked in #2101 and legacy Zig snapshots prove different contracts. Production capture gates Go UI acceptance, not the start of a focused repair. A user-facing change still needs its actual keyboard and mouse walkthrough, plus the relevant [screen snapshot review](recipes/update-snapshots.md).

## Validation

Before pushing renderer changes, run:

```bash
cd go/tui && go test ./...
mix compile --warnings-as-errors
mix protocol.gen --check
```
