# Charm TUI Renderer

The Charm renderer is the Go/Bubble Tea frontend for Minga's Semantic UI protocol and the only terminal frontend. It is the working semantic terminal reference while Rust is rebuilt as the desired long-term terminal frontend. Zig is parser/tree-sitter infrastructure only; the legacy Zig terminal renderer was removed in #2223.

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

## Editor pointer input

The TUI resolves text clicks and drags from the committed row store, terminal grapheme widths, clipping, and local scroll transform used to render the editor. It sends `editor_text_event` with the presentation ID, absolute row-store rank, row ID, and composed UTF-16 offset. The renderer maps that position to source bytes; the BEAM owns selection and editing behavior.

The input model activates the final committed text presentation for each Bubble Tea update and discards presentations it can no longer use. These lifecycle messages stay ordered with pointer input. Drag capture stays with the originating editor pane until release, including release after a stale or missing target. Chrome and overlays retain their input precedence. See [the input ownership contract](ARCHITECTURE.md#the-input-rule) and [the wire format](PROTOCOL.md#0x1e-editor_text_event).

## Validation

Before pushing renderer changes, run:

```bash
cd go/tui && go test ./...
mix compile --warnings-as-errors
mix protocol.gen --check
```
