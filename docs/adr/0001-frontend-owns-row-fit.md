# ADR-0001: Frontends own row fit; the BEAM never derives row counts from pixels or line spacing

**Status:** Accepted (2026-07-02). Implementation: #2694. Prehistory: #2674, #2687, #2692, #2693.

## Decision

Each frontend computes how many rows fit its content area — `floor(content_pixels / (cell_height × line_spacing))`, one integer floor, in the one layer that can see pixels — and reports that number in `ready`/`resize`. The BEAM lays out in the rows it is given. Line spacing is a draw-time rendering hint (opcode 0x92) and has **zero** influence on BEAM-side layout, viewport, or scroll math. `Viewport.effective_rows/2` is deleted, not deprecated.

## Context: the bug class this kills

Before this decision, row fit was computed twice, in two processes, in two different units, with an integer floor at each step: the GUI floored pixels into **unspaced raw cells** and sent that; the BEAM floored raw cells into **spaced effective rows**. Every conversion loses up to a row; the two sides can silently disagree; and chrome reservations were subtracted in cell units by whichever side believed it owned them. In July 2026 this produced three user-visible bugs in two days (#2674 underfill mis-attribution, #2687 remainder band, #2693 phantom-chrome row loss), each initially blamed on line spacing.

VSCode and Zed have no such bug class: rows-that-fit is a presentation fact computed once, pixel-natively, where the pixels live. Our cell-grid wire unit is terminal heritage; the GUI does not need to impersonate a terminal to share the semantic protocol.

## The trap for future sessions (read this before "fixing" line height)

If a layout bug *smells like* "line height / line spacing broke the viewport" — underfilled windows, missing rows, bands below content, cursor math off by a few rows — the actual defect is one of:

1. **A unit conversion between pixels, unspaced cells, and spaced rows** happening on the wrong side of the process boundary (the BEAM must never perform one), or
2. **Chrome double-booking**: rows reserved for modeline/minibuffer/status chrome that the GUI renders natively.

Do **not** reintroduce spacing arithmetic on the BEAM, an `effective_rows`-style second derivation, or a compensating clamp in a consumer. Those were our model; the ledger above is why they fail. Fix the unit ownership or the reservation, at the layer that owns it.

## Alternatives rejected

- **BEAM derives effective rows from raw cells + spacing** (the prior model): double floors, cross-process disagreement, and every symptom mis-attributed to line height. Rejected by the July 2026 ledger.
- **Sending pixel dimensions to the BEAM**: moves pixel math to a layer that cannot see fonts or backing scale; the BEAM would own geometry it cannot verify, inverting the AGENTS.md Ownership section.
- **Keeping both paths behind a capability**: preserves the bug class for whichever path is less exercised.

## Consequences

The wire `rows` field means "content rows available at current presentation metrics." The TUI reports its cell rows unchanged (spacing is 1.0 by construction). Runtime spacing changes re-fit on the frontend and arrive as an ordinary resize. Net code deletion on the BEAM; the only remaining floor lives next to the pixels it measures.
