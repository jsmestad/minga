# ADR-0005: Frontends own immediate UI feedback over committed models

**Status:** Accepted direction (2026-11-17). Not implemented or benchmarked by this record.

## Decision

Minga targets visible feedback on the next available frame for interactions the frontend can present from its committed model. A busy BEAM must not delay feedback that needs no new editor decision. Optimize the input-to-display path, not just the speed of the round trip.

- **Keep presentation local when it is safe to discard.** Frontends own pointer and gesture capture, measurement, animation, and previews backed by committed data. They must use the same displayed model and transform for drawing and hit testing.
- **Keep semantic decisions in the BEAM.** Frontends send ordered intents and do not predict edits, cursor movement, selection, or other authoritative outcomes. If an interaction needs new data or a BEAM decision, the frontend can acknowledge the input locally but must not show the action as completed before it commits. New authoritative state supersedes any local preview.
- **Supply enough data for the interaction.** For a bounded navigable surface, prefer a resident semantic model with incremental updates over a visible slice that requires a new frame on every input. Preserve fast first paint and measure startup, memory, and edit cost as well as gesture latency.

## First application: soft-wrapped scrolling

A trackpad must reveal the last displayed row without a keyboard command. The current wheel path clamps logical line counts against screen rows. One logical line that wraps to six rows cannot scroll in a four-row viewport. Fixing the clamp alone still leaves fast gestures at the mercy of the next BEAM frame if the frontend only has a slice.

Extend the [resident row store](https://github.com/jsmestad/minga/blob/main/docs/workstreams/resident-scroll.md) to eligible soft-wrapped editor panes on macOS and the TUI. Residency means the frontend holds all laid-out rows for the pane, not just the visible slice. Ship correct wrapped EOF and immediate local movement together for eligible panes. Folded residency is outside this application.

- **The BEAM owns layout and committed position.** It provides the laid-out rows, their stable identities, and the scroll bounds. It commits ordered scroll intents against visual rows, including moves within one logical line, without moving the buffer cursor. An authoritative jump supersedes local movement.
- **The frontend owns immediate presentation.** Swift translates resident rows in pixels for trackpad gestures. Go moves the displayed slice in whole terminal rows. Neither rewraps the source nor guesses EOF from logical lines or the current payload. A scroll report must reconcile with the committed position without a duplicate move, a jump on release, or leftover motion that delays reversal at EOF. [ADR-0001](0001-frontend-owns-row-fit.md) still governs how many rows fit.
- **Reuse the existing residency lifecycle.** Keep fast first paint. Once resident, scrolling must not rewrap or resend the whole document. Ordinary local edits update affected rows by identity. A width change can rebuild the wrap layout. Qualify residency against the cost of laid-out rows and memory, not just the number of source lines. Panes outside the residency budget still need correct visual-row movement and EOF, but do not carry the same no-round-trip performance promise.

## Alternatives not selected

- **Wait for every commit.** This fixes reachability but makes visible motion depend on render and transport latency. It is not the target for eligible panes.
- **Keep a fixed window of extra rows.** This can cover slow gestures, but a fast fling can outrun the cached rows. Do not bring back velocity-aware prefetch to compensate.
- **Wrap in each frontend.** This duplicates layout and can make drawing, hit testing, and subsequent editor commands disagree about which row the user saw.

## How to judge the result

For any surface applying this decision, measure input to first visible feedback under normal load and while the BEAM is busy. Record stalls during continuous input and verify that local presentation yields cleanly to an authoritative update. Compare platform-native behaviors rather than requiring the TUI to reproduce pixel animation.

- Start with one logical line that wraps to six distinct rows in a four-row pane. Scroll one row, fling to EOF, then reverse without lifting. The last continuation is reachable, the first accepted reverse step moves back immediately, and the cursor stays put. Also cross logical line boundaries in both directions.
- With a warm resident store, compare slow drag and fast fling on the same file and equivalent viewport in macOS Minga, Zed, and VS Code. Record input-to-first-visible-movement latency and any mid-gesture stalls, including while BEAM rendering is busy. Minga should move on the next available frame without waiting for a BEAM commit. For the TUI, compare whole-row behavior with [Neovim `smoothscroll`](https://neovim.io/doc/user/options.html#%27smoothscroll%27) enabled, not pixel animation.
- Replay committed row-store updates and scroll intents in both frontends. Include a same-logical-line commit, an EOF clamp, and a resize or authoritative jump while local movement is pending. Check that scroll frames do not rebuild or resend the resident document and that a local edit does not trigger a full replacement.

These are acceptance criteria, not a claim of measured parity.
