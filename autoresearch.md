# Autoresearch: render dirty-row update speed

## Objective
Apply the same structural-update mentality from tree-sitter highlighting to editor rendering. The benchmark runs the headless editor on a 2,000-line buffer, sends repeated insert-mode keys, and measures end-to-end key latency plus render stage timings. Optimize for preserving previous render state and recomputing/emitting only what changed after a one-line edit, without breaking visible output.

## Metrics
- **Primary**: `key_latency_us` (µs, lower is better) — median wall-clock time from key input to collected headless frame for insert-mode edits.
- **Secondary**: `insert_p95_us`, `motion_latency_us`, `input_dispatch_us`, `render_us`, `port_emit_us`, `content_stage_us`, `chrome_stage_us`, `emit_stage_us` — tradeoff and localization metrics for tail latency and render/emit stages.

## How to Run
`./autoresearch.sh` outputs `METRIC name=value` lines from `mix run bench/key_latency_bench.exs`.

## Files in Scope
- `lib/minga_editor/render_pipeline/**/*.ex`, `lib/minga_editor/render_pipeline.ex` — invalidation, content, chrome, compose, emit, render cache, and frame assembly.
- `lib/minga_editor/window*.ex`, `lib/minga_editor/workspace/**/*.ex`, `lib/minga_editor/shell/**/*.ex` — dirty state, window render cache, shell frame/layer assembly, and update ownership.
- `lib/minga_editor/frontend/**/*.ex`, `lib/minga/parser/**/*.ex`, `lib/minga/port/**/*.ex` — protocol/emit paths only when benchmark evidence points there.
- `bench/key_latency_bench.exs`, `autoresearch.sh`, `autoresearch.checks.sh` — benchmark and validation harness.

## Off Limits
- Do not skip rendering required visible changes to win the benchmark.
- Do not change user-visible output semantics unless tests/snapshots are updated intentionally.
- Do not weaken HeadlessPort/test frame contracts unless a dedicated compatibility path preserves existing tests.
- Do not hardcode benchmark dimensions, document contents, or key sequences in production code.

## Constraints
- Primary metric decides keep/discard. Keep only lower `key_latency_us` unless a secondary metric exposes a correctness or catastrophic regression.
- `./autoresearch.checks.sh` must pass before keeping any code change.
- Preserve GUI-first architecture and TUI/headless compatibility.
- Prefer structural update reductions: dirty-row caches, per-window render cache reuse, chrome fingerprinting, delta emit, avoiding full command-list/frame rebuilds, and incremental splicing over full recomputation.

## What's Been Tried
- Earlier render autoresearch kept several micro-optimizations: direct TUI full-frame layer emit, render-cache dirty checks, and no-wrap single-row inlining. Those helped but were edge trimming.
- Tree-sitter structural autoresearch showed the intended pattern: incremental parse plus changed-range highlight caching cut update latency by an order of magnitude. Apply that mindset here.
