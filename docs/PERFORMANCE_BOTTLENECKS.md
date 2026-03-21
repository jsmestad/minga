# Performance Bottleneck Analysis

**Date:** 2026-03-15 (updated 2026-03-21)
**Focus:** End-user latency and AI agent edit throughput
**Related:** [Epic #911](https://github.com/jsmestad/minga/issues/911), [Telemetry ticket #527](https://github.com/jsmestad/minga/issues/527), [PERFORMANCE.md](PERFORMANCE.md), [BUFFER-AWARE-AGENTS.md](BUFFER-AWARE-AGENTS.md)

## Summary

The editor's core architecture is sound for performance: dirty-line tracking, incremental tree-sitter sync via EditDelta, render debounce at 16ms, BEAM VM tuning, and ETS for read-heavy shared state all work well. The bottlenecks below are specific, fixable problems rather than architectural flaws.

The single most impactful remaining fix is routing agent edits through the buffer instead of the filesystem. Telemetry infrastructure (P2) is now in place, so subsequent optimizations can be data-driven.

## Priority-Ordered Bottlenecks

### P1: Agent File Edits Bypass Buffers — [#905](https://github.com/jsmestad/minga/issues/905)

**Impact:** HIGH for AI agent workloads. Zero impact on human editing.
**Effort:** Medium. Pattern documented in BUFFER-AWARE-AGENTS.md.

Agent tools (`EditFile`, `MultiEditFile`, `WriteFile`) all go through the filesystem:

```
Agent edit → File.read → String.replace → File.write → FileWatcher → buffer reload → tree-sitter full reparse
```

For 20 edits to one file, this means:
- ~140 syscalls (7 per read/write cycle × 20)
- 20 FileWatcher notifications
- 20 potential tree-sitter full reparses
- 0 undo entries (changes aren't tracked)
- Race condition with user's active editing

`MultiEditFile` batches edits in memory (one read, one write), but still pays the FileWatcher and reparse costs.

The buffer already has `Buffer.Server.apply_text_edits/2` which would give:
- 0 syscalls
- 0 FileWatcher events
- 1 incremental tree-sitter reparse (via EditDelta)
- 1 undo entry (the entire batch)
- No race condition (serialized through the buffer's GenServer mailbox)

**Fix:** Add a `BufferRouter` module that resolves file path to buffer pid (if open) and routes through `apply_text_edits/2`. Fall back to filesystem I/O when no buffer exists. The string-match-to-position conversion can use `:binary.matches` to find offsets, then `Document.offset_to_position` (already exists) to convert.

**Why first:** Every agent feature built on filesystem I/O inherits this performance tax. The longer this waits, the more code depends on the slow path.

### P2: Telemetry Infrastructure (#527) ✅ DONE

**Status:** Implemented. `Minga.Telemetry` provides a thin wrapper over `:telemetry` with `span/3` and `execute/3`. The render pipeline, editor input dispatch, and command execution are all instrumented with named spans. `Minga.Telemetry.DevHandler` routes span durations through `Minga.Log.debug` and is attached at startup.

**Instrumented spans:**

| Span | Status |
|------|--------|
| `[:minga, :render, :pipeline]` | ✅ In `RenderPipeline` |
| `[:minga, :render, :stage]` | ✅ All 7 stages (invalidation, layout, scroll, content, agent_content, chrome, compose) |
| `[:minga, :input, :dispatch]` | ✅ In `Editor` |
| `[:minga, :command, :execute]` | ✅ In `Editor.Commands` |
| `[:minga, :port, :emit]` | ✅ In `RenderPipeline` |
| `[:minga, :buffer, :operation]` | Not yet instrumented |
| `[:minga, :agent, :tool]` | Not yet instrumented |

Set `:log_level_render` to `:debug` to see per-stage timing in `*Messages*`. The remaining two spans (buffer operations, agent tools) can be added when those subsystems need profiling.

### P3: Motion Execution Copies Full Document Across Process Boundary — [#906](https://github.com/jsmestad/minga/issues/906) / [#907](https://github.com/jsmestad/minga/issues/907)

**Impact:** HIGH for human editing on large files. Proportional to file size.
**Effort:** Quick win (low), structural fix (medium-high).

`Helpers.apply_motion` does:
1. `BufferServer.snapshot(buf)` copies the full `Document.t()` to the Editor process
2. Runs the motion function on it
3. `BufferServer.move_to(buf, new_pos)` sends the result back

For a 50K-line file (~3MB), every motion copies 3MB across the process boundary. But the severity varies by motion type:

| Motion | Snapshot needed? | Content materialized? | Cost |
|--------|------------------|-----------------------|------|
| `j`, `k` (up/down) | No (uses `BufferServer.move` directly) | No | Low |
| `h`, `l` (left/right) | Yes (checks boundary) | No | Medium |
| `0`, `$`, `^` (line) | Yes (snapshot) | No, uses `line_at` | Medium |
| `w`, `b`, `e` (word) | Yes (snapshot) | Yes (`content()` = O(n) concat) | **High** |
| `gg`, `G` (document) | Yes | No | Medium |

Word motions are the worst: they call `Readable.content(buf)` which concatenates `before <> after_` into a new binary, then search through it.

**Quick win:** For `h` and `l`, replace `snapshot` + boundary check + `move` with a single GenServer call `move_if_possible(buf, :left)` that does the check inside the buffer process. Eliminates the snapshot for the most common keystrokes.

**Structural fix:** Rewrite word motions to use `line_at` iteratively instead of materializing full content. Word motions search forward/backward from the cursor and rarely need more than 2-3 lines of context. This eliminates the O(n) content materialization entirely.

### P4: Undo Stack Stores Full Document Snapshots — [#908](https://github.com/jsmestad/minga/issues/908)

**Impact:** MEDIUM. Bounded by coalescing (300ms) and stack cap (1000 entries).
**Effort:** High. Fundamental change to undo architecture.

`BufState.push_undo` stores `{version, document}` where `document` contains the full file as `before` + `after` binaries. Worst case for a 1MB file with 1000 undo entries: ~1GB in the buffer process heap.

In practice, the 300ms coalescing window limits human typing to 2-3 entries/second. Agent edits via `apply_text_edits/2` push one entry per batch, which is manageable. The real problem is the current agent path: filesystem writes trigger buffer reloads, and each reload may push a snapshot.

**Fix (when telemetry proves it matters):** Delta-based undo. Store the inverse operation (what was deleted/inserted + cursor positions) rather than the full document. This is how every production editor does it. Each entry shrinks from ~file_size to ~edit_size.

**Why deferred:** The coalescing window and stack cap bound the worst case. For typical files (10-50KB), the peak is 10-50MB, which is fine. Fix agent buffer routing (P1) first, which eliminates the reload-pushes-snapshot problem.

### P5: Scroll Stage GenServer Call Volume — [#909](https://github.com/jsmestad/minga/issues/909)

**Impact:** MEDIUM. Already partially optimized via `render_snapshot`.
**Effort:** Low-medium.

The scroll stage makes 4-7 `BufferServer` calls per window per frame:
- `line_count` (1 call)
- `cursor` (1 call, active window only)
- `decorations` (1 call)
- `render_snapshot` (1 call, already batches 5 old calls)
- `get_option` × 2 (line_numbers, wrap)
- Conditionally: `file_path` for git signs

At 60fps, that's ~300-420 GenServer round-trips/second per window. Each GenServer call in the BEAM is 1-5µs, so the total overhead is maybe 1-2ms/second. **Measure with telemetry before optimizing.**

**Fix (if telemetry shows it matters):** A single `scroll_snapshot` call that returns everything the scroll stage needs: line count, cursor, decorations, render snapshot, options, file path. One round-trip instead of 4-7.

### P6: Line Index Cache Invalidation on Mutation — [#910](https://github.com/jsmestad/minga/issues/910)

**Impact:** LOW-MEDIUM. Already well-designed.
**Effort:** Medium (incremental update is tricky for multi-line edits).

`Document.line_offsets` is lazily computed and invalidated (set to `nil`) on content mutations. The rebuild cost is `content()` (O(n) concatenation) + `:binary.matches` (single-pass C-level scan, fast). For a 50K-line file: ~1-2ms.

The invalidation is narrower than it appears: only `move_to` and content mutations set `line_offsets: nil`. Regular `move(:left/:right/:up/:down)` preserves the cache.

If agent edits route through `apply_text_edits/2` (P1 fix), they're batched, so you get one invalidation per batch, not per edit.

**Fix (when telemetry proves it matters):** Incremental offset update. Given an EditDelta, adjust offsets above the edit point rather than rebuilding from scratch.

### P7: Render Pipeline Runs in the Editor GenServer

**Impact:** LOW today. Could become medium as UI complexity grows.
**Effort:** High (major architectural change, not recommended now).

Every render frame blocks the Editor from processing input. If a render takes 5ms (plausible for complex syntax highlighting + chrome), that's 5ms of input latency on top of the 16ms debounce. At current complexity, this is fine. It would become a problem if future features add expensive render stages (LSP diagnostics overlay, inline diffs, rich agent UI).

**Not recommended now.** Moving rendering to a separate process requires snapshotting all render state atomically, which is a significant change. Monitor via telemetry first.

## Bottlenecks Identified by Archie

### `Document.move_to/2` is O(n) for Long-Distance Jumps

The gap buffer moves the cursor by shifting bytes between `before` and `after`. A jump from line 0 to line 50,000 rebuilds the entire gap. This matters for `gg`/`G` and for agent edits that jump around the file. This is inherent to gap buffers and not fixable without changing the data structure.

### Agent Tool String Matching is O(n×m)

`EditFile` uses `String.split(content, old_text)` to count occurrences, then `String.replace` to apply. For large files with long search strings, that's two full scans. If routed through the buffer (P1 fix), the tool layer needs to convert string matches to positions first, then hand off positions to `apply_text_edits/2`.

## What Already Works Well

These don't need optimization:

| System | Why it's fine |
|--------|---------------|
| Dirty-line tracking | Single-char edits re-render one line, not the whole viewport |
| Line index cache (when valid) | O(1) `line_at` via `binary_part` on cached offsets |
| Incremental tree-sitter sync | EditDelta sends compact diffs to the parser, not full content |
| Render debounce (16ms) | Coalesces rapid edits into single frames |
| BEAM VM flags | Scheduler wake, GC tuning, allocator config all well-configured |
| ETS for read-heavy state | Config.Options, Diagnostics, Keymap.Active bypass GenServer |
| `render_snapshot` batching | 5 old calls consolidated into 1 |
| Undo coalescing | 300ms window prevents stack explosion during human typing |

## Recommended Execution Order

```
1. Agent buffer routing (#905)       ← biggest win for AI workloads
2. Motion quick win: h/l (#906)      ← low effort, high frequency
3. Word motion refactor (#907)       ← eliminates O(n) per keystroke
4. [measure with telemetry]          ← verify remaining items matter
5. Delta undo (#908)                 ← if memory profiling shows pressure
6. Scroll snapshot (#909)            ← if telemetry shows GenServer overhead
7. Line index incremental (#910)     ← if telemetry shows rebuild cost
```

Telemetry (P2) is done. Steps 4-7 are conditional. Telemetry may reveal that some are already fast enough, or that an unidentified bottleneck is the real problem.
