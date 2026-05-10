# Autoresearch: tree-sitter highlight speed

## Objective
Make syntax highlighting fast enough that parser/highlight work never shows up as editor latency. The benchmark runs the Zig `minga-parser` highlighter directly on a 2,000-line Elixir-like buffer, warms up parsing and highlight query execution, then measures repeated full parse plus `highlightWithInjections` cycles after a small source mutation.

## Metrics
- **Primary**: `ts_update_highlight_us` (µs, lower is better) — median time for parse plus highlight query execution after one source mutation.
- **Secondary**: `ts_update_highlight_p95_us`, `ts_parse_us`, `ts_highlight_us`, `ts_highlight_p95_us`, `ts_span_count`, `ts_line_count` — tradeoff and localization metrics for tail latency, parse/query split, output size, and workload size.

## How to Run
`./autoresearch.sh` outputs `METRIC name=value` lines.

## Files in Scope
- `zig/src/highlighter.zig` — tree-sitter parsing, query execution, capture collection, predicate handling, sorting, capture-name construction, injections, folds, indents, and textobjects.
- `zig/src/predicates.zig`, `zig/src/posix_regex.zig`, `zig/src/query_loader.zig` — predicate and query handling when profiling points there.
- `zig/src/parser_main.zig`, `zig/src/protocol.zig`, `zig/src/port_writer.zig` — parser port protocol and response encoding when benchmark work points there.
- `zig/src/highlight_bench.zig`, `zig/build.zig`, `autoresearch.sh`, `autoresearch.checks.sh` — benchmark and validation harness.
- `zig/src/queries/**/*.scm` — highlight query shape, only when correctness is preserved and language behavior remains intended.

## Off Limits
- Do not skip parsing, query execution, predicate evaluation, sorting, injection handling, or capture-name output to win the benchmark.
- Do not remove captures or weaken highlight correctness unless tests and intended behavior are updated in the same kept experiment.
- Do not change public parser port protocol wire formats unless benchmark evidence clearly requires it and Elixir/Swift/Zig protocol tests are updated.
- Do not add new dependencies for micro-optimizations.

## Constraints
- Primary metric decides keep/discard. Keep only lower `ts_update_highlight_us` unless a secondary metric exposes a correctness or catastrophic regression.
- `./autoresearch.checks.sh` must pass before keeping any code change.
- Preserve user-visible highlighting behavior across frontends.
- Prefer structural hot-path reductions: fewer query cursor allocations, fewer per-match C API calls, better reuse of capture names, cheaper sorting, less allocation churn, and safe incremental parse/query improvements.

## What's Been Tried
- Switched from Swift semantic rendering after reducing `swift_frame_us` from roughly 266µs to 165µs. New target focuses on the Zig tree-sitter parser/highlighter shared by all frontends.
