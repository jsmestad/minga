# Autoresearch: keystroke latency

## Objective
Make Minga feel as snappy as Neovim by reducing the measured headless keystroke-to-render latency for a realistic editing workload. The benchmark starts a headless editor on a 2,000-line Elixir-like buffer, warms up normal-mode motion and insert-mode typing, then measures 120 insert-mode keystrokes across 5 fresh editor runs.

## Metrics
- **Primary**: `key_latency_us` (µs, lower is better) — median insert-mode keypress wall time from sending the key event to receiving the rendered frame.
- **Secondary**: `insert_p95_us`, `motion_latency_us`, `input_dispatch_us`, `render_us`, `port_emit_us`, `content_stage_us`, `chrome_stage_us`, `emit_stage_us` — tradeoff and localization metrics from telemetry.

## How to Run
`./autoresearch.sh` outputs `METRIC name=value` lines.

## Files in Scope
- `lib/minga_editor.ex` — Editor GenServer input hot path and key event routing.
- `lib/minga_editor/input/router.ex` — focus-stack dispatch, snapshots, and post-action housekeeping.
- `lib/minga_editor/renderer.ex` and `lib/minga_editor/renderer/server.ex` — synchronous and split render entry points.
- `lib/minga_editor/render_pipeline*.ex` and `lib/minga_editor/render_pipeline/*.ex` — render pipeline stages and caches.
- `lib/minga_editor/frontend/*.ex` — command emission and protocol conversion.
- `lib/minga/buffer/server.ex`, `lib/minga/buffer/document.ex`, `lib/minga/editing/**/*.ex`, `lib/minga/mode/**/*.ex` — buffer, motion, and insert-mode hot path code when the benchmark points there.
- `bench/key_latency_bench.exs`, `autoresearch.sh`, `autoresearch.checks.sh` — benchmark and validation harness.

## Off Limits
- Do not change public protocol wire formats unless a benchmark result clearly requires it and tests/docs are updated in the same kept experiment.
- Do not disable rendering, telemetry, syntax/decorations correctness, undo behavior, or input semantics to win the benchmark.
- Do not add new dependencies for micro-optimizations.
- Do not use `Process.sleep/1` in production code.

## Constraints
- Primary metric decides keep/discard. Keep only lower `key_latency_us` unless a secondary metric exposes a correctness or catastrophic regression.
- `./autoresearch.checks.sh` must pass before keeping any code change.
- Preserve user-visible behavior. Any optimization that skips needed housekeeping must be discarded even if faster.
- Prefer structural hot-path reductions: fewer snapshots, fewer allocations, narrower invalidation, less protocol work, better cache reuse.

## What's Been Tried
- Restarted clean from `main` after prior benchmark history was invalidated by external CPU saturation. Copied only the benchmark harness and autoresearch scripts, not app-code optimizations.
