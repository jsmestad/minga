# Charm TUI Renderer

The Charm renderer is an experimental Go/Bubble Tea frontend for Minga's Semantic UI protocol. It is the working semantic terminal reference during the frontend bakeoff while Rust is rebuilt as the desired long-term terminal frontend. Zig remains relevant for parser/tree-sitter infrastructure and legacy terminal rendering until that path is retired.

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

Use `bin/minga` so the terminal device is captured correctly for the TUI port:

```bash
MINGA_TUI_IMPL=go bin/minga path/to/file
```

`MINGA_TUI_IMPL=go` tells `MingaEditor.Frontend.Manager` to launch `priv/minga-renderer-go` instead of the default TUI renderer. The Go renderer opens `/dev/tty` by default, or `MINGA_TTY` when it is set.

## Current Scope

The Charm renderer targets the Semantic UI path, not the legacy cell-grid path. It decodes and renders:

- semantic editor rows and spans
- tab bar and workspace chrome
- status bar and minibuffer
- file tree
- picker, picker preview, completion, and which-key overlays

It renders roughly 9 of the shared-chrome components today. Decoding and rendering the remaining components is tracked in #2100, and overall cross-frontend coverage is tracked in the Semantic UI inventory (#2113).

## Validation

Before pushing renderer changes, run:

```bash
cd go/tui && go test ./...
mix compile --warnings-as-errors
mix protocol.gen --check
```
