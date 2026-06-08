# ZigZag runtime boundary recommendation

Recommendation: `component-adapters-plus-zigzag-program`.

ZigZag should now mirror the Go/Bubble Tea renderer shape inside the current `minga-renderer` path. ZigZag `Program` owns terminal IO and frame presentation on the TTY. Minga still owns stdout as the BEAM Port packet channel, semantic payload meaning, command dispatch, query/filter/focus source-of-truth, selected item state, transcript state, and durable editor state.

## Why this recommendation changed

The corrected stack uses ZigZag as more than fit-check evidence. Structural chrome, overlays, hitboxes, and local presentation adapters all now use ZigZag where the component can safely adapt retained BEAM semantic payloads.

The user correction also changed the runtime target: the goal is not to keep ZigZag below the runtime line. The goal is to mirror Go/Bubble Tea with Zig/ZigZag.

The Go renderer proves the boundary:

- Bubble Tea runs the terminal UI against `/dev/tty` or `MINGA_TTY`.
- stdout remains length-prefixed BEAM Port packets only.
- BEAM owns semantic state and command dispatch.
- frontend components own local presentation, zones, viewport/cache metadata, and interaction adaptation.

The Zig runtime now follows that same shape:

- `apprt/zigzag_tui.zig` uses `zz.Program(MingaModel).initWithOptions` with both input and output pointed at `MINGA_TTY` or `/dev/tty`.
- `std.posix.STDOUT_FILENO` remains reserved for `protocol.writeMessage` and `port_writer` packets.
- The adapter loop reads BEAM packets from stdin, applies retained semantic payloads, and returns key, paste, resize, mouse, measurement, and GUI-action packets to BEAM.
- The old libvaxis runtime remains compiled as `LegacyVaxisRuntime` during the transition, but the selected `TuiRuntime` is ZigZag-backed.

## Terminal correctness and BEAM port safety

`stdout` remains reserved for BEAM packets. Minga’s renderer is a Port process. Anything written to stdout is interpreted as length-prefixed protocol data by the BEAM side. The ZigZag adapter preserves this by passing the TTY file to ZigZag `Program` as its input and output, then using `port_writer` for stdout.

The TTY is owned by ZigZag `Program`, not by stdout. This is the same split the Go renderer uses with Bubble Tea. Terminal escape sequences, alternate-screen setup, mouse tracking, bracketed paste setup, and frame presentation go to the TTY handle.

Backpressure remains owned by Minga’s `port_writer`. The adapter queues encoded packets and drains stdout through the existing non-blocking writer path. ZigZag model updates return data to that path; they do not bypass it.

## Runtime behavior evaluation

- Resize: ZigZag owns terminal-size observation, and the adapter routes resize packets back to BEAM.
- Paste: ZigZag parses bracketed paste, and the adapter sends one `paste_event` packet to BEAM.
- Keyboard: ZigZag parses terminal keys, and the adapter maps them to Minga key codepoints, matching the Go renderer’s arrow, enter, escape, tab, space, and backspace mapping.
- Mouse: ZigZag parses mouse input, and the adapter first checks BEAM-owned semantic hitboxes before falling back to raw mouse packets.
- Frame presentation: ZigZag `Program` owns the terminal lifecycle while the Minga model renders retained semantic cells into a ZigZag-compatible ANSI frame string.
- Recovery: the adapter keeps signal unblocking and quit handling local to the renderer and preserves stdout recovery boundaries. BEAM responsiveness recovery remains a Minga concern layered over the adapter.
- Backpressure: `port_writer` remains the only BEAM event enqueue/drain path.

## Allowed ZigZag ownership

Allowed:

- ZigZag `Program` terminal lifecycle against the TTY.
- Component-backed presentation adapters fed by retained BEAM semantic payloads.
- Local derived view data.
- Local hitbox computation and interaction metadata.
- Local frame/cache metadata that can be recomputed from retained semantic packets.
- Measurement/layout helpers that return data to BEAM through Minga’s Port protocol.

Not allowed in this path:

- ZigZag stdout writes.
- ZigZag command dispatch.
- ZigZag durable editor state.
- ZigZag ownership of semantic payload meaning, query/filter/focus state, selected item state, or command acceptance.
- A permanent `minga-renderer-zigzag` binary or product path.

## Input to the #2191 final decision

Keep ZigZag as the terminal framework for the current Zig renderer, but with the same ownership split as Go/Bubble Tea. ZigZag can own the TTY runtime and component presentation. BEAM remains the editor brain and stdout protocol owner.
