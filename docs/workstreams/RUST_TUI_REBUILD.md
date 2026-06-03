# Rust TUI Rebuild Workstream

This workstream proves whether Ratatui plus a modern terminal stack can deliver the same Semantic UI polish as the Swift frontend while remaining easier to maintain than the current Rust TUI and temporary Go TUI.

## Decision

The Rust TUI should be rebuilt as a semantic-only terminal frontend. It should not patch the current mixed legacy-cell and semantic renderer until it works by accident. The new shape is `BEAM protocol -> retained Semantic UI state -> Ratatui widgets -> Terminal`, with input and resize events flowing back to the BEAM over the existing port protocol.

## Direction

- Minga emits one Semantic UI stream for visible shared UI.
- Frontends declare capabilities such as terminal grid, pixel surface, text measurement, color support, images, floats, and host mode.
- Minga does not branch on Swift, Rust, Go, GTK, or terminal identity for product behavior.
- The Rust TUI is a native terminal frontend, not a desktop GUI.
- Go remains the temporary known-good semantic terminal reference during the bakeoff.
- Zig remains responsible only where parser/tree-sitter work still depends on it.

## Non-Goals

- Do not keep non-semantic TUI rendering as a supported product path.
- Do not make the Rust rebuild depend on Go runtime code.
- Do not port Zig parser/tree-sitter code as part of the first Rust renderer proof.
- Do not redesign the editor kernel, agent runtime, or shell model inside Rust frontend tickets.
- Do not add frontend-specific BEAM policy branches beyond capability negotiation.

## Architecture

The Rust terminal frontend should keep the BEAM process boundary intact.

- **Spawned mode:** BEAM starts the Rust frontend as a port process and supervises it.
- **Connected mode:** a native host or terminal wrapper can start the BEAM and connect over stdin/stdout-compatible framing.
- **Future client/server mode:** the protocol and process boundary remain compatible with remote or multi-client frontends because editor state stays in the BEAM.

The Swift app is the startup quality reference: it owns host startup, launches or connects to BEAM with explicit environment, observes lifecycle, and treats the BEAM as the source of truth. Rust should mirror that discipline for terminal startup without copying SwiftUI structure.

## Proof Checklist

- Extended `ready` reports semantic UI support and terminal capabilities.
- BEAM startup or connection mode works without terminal ownership races.
- Semantic UI packets decode into retained Rust state without relying on legacy draw fallbacks.
- Ratatui renders windows, chrome, gutters, cursor, selections, status, minibuffer, file tree, picker, completion, which-key, and agent surfaces from semantic state.
- Input events, resize events, mouse events, and shutdown flow back to BEAM correctly.
- Terminal resize and scroll do not corrupt retained state.
- Unknown forward-compatible semantic opcodes are skipped safely when the envelope permits it.
- Snapshot or trace fixtures compare Rust behavior against the Go semantic reference where useful.
- Focused Rust tests cover protocol decode, semantic state transitions, and key rendering decisions.

## First Ticket Stack

### Ticket 1: Lock Semantic UI Direction

Issue: https://github.com/jsmestad/minga/issues/2155

Goal: make the frontend contract direction explicit in docs and runner guidance so agents stop introducing GUI-vs-TUI protocol splits.

Acceptance criteria:

- Documentation states that Minga emits one Semantic UI contract for GUI and terminal clients.
- Documentation states that frontend identity is opaque to Minga product behavior and capabilities drive adaptations.
- Stale references that describe GUI chrome as native-GUI-only are either updated or called out as historical naming to be renamed.
- Non-semantic UI support is marked dead scope except for deletion or temporary buffer-window compatibility explicitly tracked by a ticket.

### Ticket 2: Remove Non-Semantic Frontend Support

Issue: https://github.com/jsmestad/minga/issues/2156

Goal: remove or quarantine old non-semantic frontend rendering support so new agents cannot accidentally build against it.

Acceptance criteria:

- BEAM-side frontend emit code has a single semantic path for shared UI.
- Legacy cell-grid TUI support is either deleted or isolated behind an explicit temporary compatibility boundary with fail-loud behavior.
- Go and Rust frontend code no longer silently falls back to legacy cell rendering for shared chrome.
- Tests or guardrails fail when a shared chrome feature is added only as cell draw commands.

### Ticket 3: Build Fresh Rust Semantic TUI Skeleton

Issue: https://github.com/jsmestad/minga/issues/2157

Goal: create the clean Rust terminal frontend skeleton that starts from the semantic contract and Ratatui terminal lifecycle instead of the current mixed renderer.

Acceptance criteria:

- Rust TUI has clear modules for protocol decode, semantic state, terminal lifecycle, input encode, BEAM host/connection lifecycle, and Ratatui rendering.
- Startup sends extended semantic capabilities and receives BEAM frames without blocking terminal input.
- The first renderer can show a minimal semantic frame with status/minibuffer/window content from semantic packets.
- Legacy draw commands are not the normal shared-chrome rendering path.
- Focused Rust tests cover ready encoding, semantic decode, retained state update, and at least one rendered semantic surface.
