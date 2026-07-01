# Resident-Store Rendering Direction

**Status:** Approved direction, June 2026. Tracked by epic [#2652](https://github.com/jsmestad/minga/issues/2652). This doc captures the decision and its rationale so future work (human or agent) builds toward it instead of extending the machinery it deletes. The normative protocol spec lands in `GUI_PROTOCOL.md` and `ARCHITECTURE.md` as the epic's implementation ships; until then, this doc describes the target, not current behavior.

## The problem

Fast, smooth scrolling is feature #1 in an editor, and it has been our top source of recurring bugs. The cause is structural: the BEAM sends frontends only a viewport-plus-overscan slice of each document, and a scroll compositor on each frontend reconciles local scroll motion against committed BEAM frames with roughly ten invalidation triggers (retained-row misses, overscan exhaustion, base mismatches, velocity refill). Hiding a process boundary at 120Hz is genuinely hard, and every seam shows up as a rendering glitch. The windowed slice is a bandwidth optimization for a remote client-server mode that has not shipped, paid for daily by the local frontends that have.

## The decision

Make the document fully resident in the frontend for normal-size files, so scrolling never outruns the data:

- **Full residence.** The BEAM sends the full laid-out document for visible windows. The BEAM keeps layout authority (wrapping, folds, `row_id`, `content_hash`, highlight spans); frontends hold all of it and scroll locally. Rasterization stays frontend-private and windowed near the viewport (texture atlas, LRU), so memory stays bounded: data is cheap, pixels are not.
- **Presentation vs position.** The frontend owns scroll *presentation*: an ephemeral, discardable local offset applied same-frame. The BEAM owns scroll *position*: the committed anchor, the cursor, and scrolloff enforcement. The frontend reports scroll intent promptly on the same ordered channel as key events; BEAM-authoritative jumps always win via a scroll-authority sequence number. One value, one writer, each.
- **Two update paths, both already built.** `layout_generation` change (resize, font, wrap, fold) → full store replace. `content_epoch` change (edits) → existing 0xA2 row-deltas keyed by `row_id + content_hash`. Cursor motion rides 0xA0 and never touches the store. Full-document re-send per keystroke was considered and rejected: it regresses edit latency to O(document).
- **Huge files are refused, not degraded.** Above a byte-size gate checked before buffer load (default 10MB, config-overridable, final number gated on encode-time measurement), Minga shows a text-only "File too large for Minga V1" surface suggesting another editor. No button, no degraded scroll mode, no silent fallback to the old compositor.
- **The compositor gets deleted.** The scroll reconciliation state machine and the velocity-aware overscan prefetch are removed from the BEAM and both frontends once conformance passes on both. The 0xA2 content-delta ref-miss guard stays; it is content-addressed, not positional, and "no reconciliation" applies to the scroll path only.

## The principle, generalized

Ship the frontend the whole navigable model, not the visible slice. Keep the BEAM authoritative for anything that mutates state or gets hit-tested. Let presentation be a discardable local transform over committed data. Every place the design sends a window of something and reconciles it is a candidate for this treatment; every piece of cleverness deleted from the frontend contract is one less thing to keep identical across Swift, Go, and the future GTK4 frontend.

Applied and approved so far:

- Buffer scrolling: epic [#2652](https://github.com/jsmestad/minga/issues/2652), ready-now slice [#2653](https://github.com/jsmestad/minga/issues/2653).
- Agent chat transcript residency: [#2654](https://github.com/jsmestad/minga/issues/2654), after #2652's store lifecycle lands.
- Live resize as local presentation with debounced re-layout: [#2655](https://github.com/jsmestad/minga/issues/2655).

Considered and deliberately skipped for now (revisit only with evidence of real latency pain): local fuzzy-filtering in pickers/completion (duplicates match semantics per frontend), keymap-trie prefetch for instant which-key, and local incremental-search highlighting (duplicates regex semantics; prefer BEAM-computed match spans over the resident store).

## Anti-goals

These boundaries were litigated and stand:

- **Cursor motion and selection stay BEAM-owned.** The responsiveness epic (#2445) dropped cursor prediction for good reason; the frontend never moves the cursor. Wheel motion that would drag the cursor past scrolloff is a cursor move and therefore BEAM work.
- **No windowed runtime fallback in v1.** The store contract (keyed row map, global `content_epoch` delta base, client-local scroll offset) is designed so windowing can return later as an additive mode for remote thin clients in the daemon epic. That deferral is deliberate and recorded here, not a silent loss.
- **This is not "move logic to the frontend."** The pattern is resident data plus local presentation, never local semantics.

## What this means for new work

- Do not extend the scroll compositor, overscan sizing, or velocity prefetch (`lib/minga_editor/render_pipeline/buffer_prefetch.ex`); that machinery is scheduled for deletion under #2652.
- New scrollable surfaces adopt the #2652 store lifecycle rather than inventing per-surface reconciliation.
- The texture retention key is `row_id + content_hash` across `content_epoch` changes, invalidated only on `layout_generation`. Treat this as a hard invariant.
- Conformance for anything touching this contract means both transcript kinds: store transcripts (frames → expected store state) and input transcripts (frames + local offset + input → expected anchor/cursor/action).
