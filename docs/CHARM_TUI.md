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

Go is the default terminal frontend, so `bin/minga` launches it. Use `bin/minga` (not `mix minga`) so the terminal device is captured correctly for the TUI port:

```bash
bin/minga path/to/file
```

`MingaEditor.Frontend.Manager` launches `priv/minga-renderer-go` by default. The Go renderer opens `/dev/tty` by default, or `MINGA_TTY` when it is set (the BEAM launch path sets `MINGA_TTY` automatically). Set `MINGA_FRONTEND=zig` to fall back to the legacy Zig renderer; any other value of `MINGA_FRONTEND` is an error.

## Current Scope

The Charm renderer targets the Semantic UI path, not the legacy cell-grid path. It decodes and renders:

- semantic editor rows and spans
- tab bar and workspace chrome
- status bar and minibuffer
- file tree
- picker, picker preview, completion, and which-key overlays

It renders roughly 9 of the shared-chrome components today. Decoding and rendering the remaining components is tracked in #2100, and overall cross-frontend coverage is tracked in the Semantic UI inventory (#2113). Board-specific rendering is not part of Charm TUI parity; Board experiments must stay extension-owned or use generic extension panels/overlays.

## Validation

Before pushing renderer changes, run:

```bash
cd go/tui && go test ./...
mix compile --warnings-as-errors
mix protocol.gen --check
```
