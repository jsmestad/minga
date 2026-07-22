# Resident-Store Rendering Direction

**Status:** Complete. Epic [#2652](https://github.com/jsmestad/minga/issues/2652) shipped end to end: full-document residence is **on by default** as of [#2679](https://github.com/jsmestad/minga/issues/2679) (`resident_store_max_lines` defaults to `65_536`, the reviewed residence/performance ceiling, with GUI window-content row counts and row-delta count/index fields encoded as u32 on the wire), and the velocity-aware overscan prefetch machinery was deleted from the BEAM and both frontends in [#2680](https://github.com/jsmestad/minga/issues/2680). This doc captures the decision and its rationale so future work (human or agent) builds on the resident-store model instead of reinventing the machinery it replaced. The normative protocol spec lives in `GUI_PROTOCOL.md` and `ARCHITECTURE.md`.

**Feel-track follow-ups shipped:** scrollbar thumb-drag now renders same-frame from resident rows — [#2665](https://github.com/jsmestad/minga/issues/2665). The drag applies the target-line delta as the existing local offset over resident rows (throttled to one intent per frame on the ordered channel), and the BEAM's `scroll_to_line` commit path got the same `mark_scroll_echo` + `record_scroll_event` treatment as the wheel free-scroll (`GuiActionHandler.scroll_to_line_commit`), so releasing commits without a settle-jump and the cursor stays put (VSCode semantics). The Swift side is a pure `ThumbDragSession` state machine (gate fixed at drag start, throttle, release baselines, authoritative-interrupt bailout, and a reconcile watchdog) owned by `EditorNSView`.

**Deferred remnants (candidate follow-ups, not regressions):** wrapped/folded residence (still uses the windowed emit path; needs visual-row offset math); residual O(document) cheap passes at the 65k ceiling (~30 fps resident scroll at the extreme; delta-only row-list construction, only if >5k-line residence matters post-launch); the discrete-wheel-tick-into-boundary one-cell park (standalone micro-fix; #2665 did **not** fold it in — thumb drag uses a separate presentation path, so `seedDiscreteScrollAnimation`'s missing `presentationScrollBoundaryAvailability` gate was untouched and still owed); the `fullRefresh`-without-`resetRequired` promotion discard-gate verification (BEAM forces full_refresh on promotion, so no live-settle cancel gap is expected, but it was flagged for a smoke check); and the Go rows-without-scroll `ScrollSet`-clearing divergence from Swift (`model.go`, harmless today, would surface only under a rows-without-scroll transcript).

## Status ledger (as of #2679)

The prerequisites the epic set for the default flip have all landed:

- Incremental resident store, edit frames O(changed rows) — [#2658](https://github.com/jsmestad/minga/issues/2658). Wall-clock evidence: single-line edit on a 5,000-line resident buffer is ~1 ms p50 / ~1.1 ms p95, flat across sizes; the operation-count CI gate is `test/minga_editor/render_pipeline/resident_incremental_test.exs`.
- GUI free-scroll zone renders locally — [#2661](https://github.com/jsmestad/minga/issues/2661).
- Same-top jump discard gap closed (explicit `bump_scroll_seq` at authoritative call sites) — [#2678](https://github.com/jsmestad/minga/issues/2678).
- Huge files refused pre-load above `:max_file_size` — [#2673](https://github.com/jsmestad/minga/issues/2673).
- Conformance runs zero-skip on both frontends.

**First-paint-then-promote (#2679).** File-open first paint at the 65k-row ceiling was measured at ~0.5 s for a full resident build versus ~0.7 ms for the windowed path, so residence now engages one frame after first paint: a newly opened or resized window renders viewport-windowed first (instant content), then promotes to full residence on the next frame. The expensive O(document) first build lands on the renderer process after content is on screen, not blocking first paint. The promotion is carried by `residence_armed` in the window render cache and resets on layout_generation rebuilds.

**Closed ledger items:** residence default flip (was AC4 of #2658), first-paint protection (was the ledger's evidence-gated design input). **Still open:** the manual GUI smoke session (the epic's one human gate, signed off on #2679 before merge); residual O(document) passes at the 65k extreme (~30 fps resident scroll at the ceiling; delta-only row-list construction, only if >5k-line residence matters post-launch); wrapped/folded residence (future slice, needs visual-row offset math).

## The problem

Fast, smooth scrolling is feature #1 in an editor, and it has been our top source of recurring bugs. The cause is structural: the BEAM sends frontends only a viewport-plus-overscan slice of each document, and a scroll compositor on each frontend reconciles local scroll motion against committed BEAM frames with roughly ten invalidation triggers (retained-row misses, overscan exhaustion, base mismatches, velocity refill). Hiding a process boundary at 120Hz is genuinely hard, and every seam shows up as a rendering glitch. The windowed slice is a bandwidth optimization for a remote client-server mode that has not shipped, paid for daily by the local frontends that have.

## The decision

Make the document fully resident in the frontend for normal-size files, so scrolling never outruns the data:

- **Full residence.** The BEAM sends the full laid-out document for visible windows. The BEAM keeps layout authority (wrapping, folds, `row_id`, `content_hash`, highlight spans); frontends hold all of it and scroll locally. Rasterization stays frontend-private and windowed near the viewport (texture atlas, LRU), so memory stays bounded: data is cheap, pixels are not.
- **Presentation vs position.** The frontend owns scroll *presentation*: an ephemeral, discardable local offset applied same-frame. The BEAM owns scroll *position*: the committed anchor, the cursor, and scrolloff enforcement. The frontend reports scroll intent promptly on the same ordered channel as key events; BEAM-authoritative jumps always win via a scroll-authority sequence number. Pointer input is normalized through the same pane owner and effective offset used for drawing, including settle, elastic rebound, and thumb-drag reconciliation after the initiating gesture ends. One value, one writer, each.
- **Two update paths, both already built.** `layout_generation` change (resize, font, wrap, fold) → full store replace. `content_epoch` change (edits) → existing 0xA2 row-deltas keyed by `row_id + content_hash`. Cursor motion rides 0xA0 and never touches the store. Full-document re-send per keystroke was considered and rejected: it regresses edit latency to O(document).
- **Huge files are refused, not degraded.** Above a byte-size gate checked before buffer load (default 10MB, config-overridable, final number gated on encode-time measurement), Minga shows a text-only "File too large for Minga V1" surface suggesting another editor. No button, no degraded scroll mode, no silent fallback to the old compositor.
- **The compositor gets deleted.** The velocity-aware overscan prefetch (the `scroll_prefetch_hint` opcode, the frontend runway senders, the BEAM velocity tiers and directional split) was removed from the BEAM and both frontends in #2680 after conformance passed on both. The windowed emit path survives only for wrapped/folded buffers and the brief pre-promotion arming frame, now sized with a fixed overscan. The 0xA2 content-delta ref-miss guard stays; it is content-addressed, not positional, and "no reconciliation" applies to the scroll path only.

## The principle, generalized

Ship the frontend the whole navigable model, not the visible slice. Keep the BEAM authoritative for anything that mutates state or gets hit-tested. Let presentation be a discardable local transform over committed data. Every place the design sends a window of something and reconciles it is a candidate for this treatment; every piece of cleverness deleted from the frontend contract is one less thing to keep identical across Swift, Go, and the future GTK4 frontend.

Applied and approved so far:

- Buffer scrolling: epic [#2652](https://github.com/jsmestad/minga/issues/2652), ready-now slice [#2653](https://github.com/jsmestad/minga/issues/2653).
- Agent chat transcript residency: [#2654](https://github.com/jsmestad/minga/issues/2654), after #2652's store lifecycle lands.
- Live resize as local presentation with debounced re-layout: [#2655](https://github.com/jsmestad/minga/issues/2655) — **shipped**: during a window-edge drag the GUI presents the last committed frame as a top-left crop and defers re-layout through a trailing debounce (75ms, 250ms max-wait, `LiveResizeBookkeeping` in `LiveResizeDebounce.swift`); the flush is GUI-side only (#2699 sole-emitter), the BEAM and TUI are untouched.

Considered and deliberately skipped for now (revisit only with evidence of real latency pain): local fuzzy-filtering in pickers/completion (duplicates match semantics per frontend), keymap-trie prefetch for instant which-key, and local incremental-search highlighting (duplicates regex semantics; prefer BEAM-computed match spans over the resident store).

## Anti-goals

These boundaries were litigated and stand:

- **Cursor motion and selection stay BEAM-owned.** The responsiveness epic (#2445) dropped cursor prediction for good reason; the frontend never moves the cursor. Wheel/trackpad scrolling is VSCode-style (#2684): it is viewport-only and never moves the cursor at all, so the cursor can leave the viewport and the next cursor-moving keypress re-anchors via cursor-follow. (Explicit scroll commands keep their vim cursor semantics; earlier iterations dragged the wheel cursor through scrolloff, which #2684 reverted for wheel/trackpad input.)
- **No windowed runtime fallback in v1.** The store contract (keyed row map, global `content_epoch` delta base, client-local scroll offset) is designed so windowing can return later as an additive mode for remote thin clients in the daemon epic. That deferral is deliberate and recorded here, not a silent loss.
- **This is not "move logic to the frontend."** The pattern is resident data plus local presentation, never local semantics.

## What this means for new work

- Do not reintroduce velocity-aware overscan sizing or scroll prefetch hints; that machinery was deleted in #2680. The windowed fetch in `lib/minga_editor/render_pipeline/buffer_prefetch.ex` uses a fixed overscan and serves only wrapped/folded buffers and the arming frame.
- New scrollable surfaces adopt the #2652 store lifecycle rather than inventing per-surface reconciliation.
- The texture retention key is `row_id + content_hash` across `content_epoch` changes, invalidated only on `layout_generation`. Treat this as a hard invariant.
- Conformance for anything touching this contract means both transcript kinds: store transcripts (frames → expected store state) and input transcripts (frames + local offset + input → expected anchor/cursor/action).
