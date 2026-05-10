# Autoresearch: Swift rendering speed

## Objective
Make the macOS GUI frontend feel as snappy as the headless BEAM path by reducing the measured Swift semantic window rendering cost for a realistic editing workload. The benchmark renders 80 visible semantic rows through `WindowContentRenderer` and `LineTextureAtlas`, warms the row texture cache, then measures 220 frame-style updates where one row changes and the rest are cache hits.

## Metrics
- **Primary**: `swift_frame_us` (µs, lower is better) — median time to render one semantic frame through the Swift window-content renderer and atlas path.
- **Secondary**: `swift_frame_p95_us`, `swift_cold_frame_us`, `swift_cache_hit_frame_us`, `swift_rows` — tradeoff and localization metrics for tail latency, cold rasterization, all-cache-hit overhead, and workload size.

## How to Run
`./autoresearch.sh` outputs `METRIC name=value` lines.

## Files in Scope
- `macos/Sources/Renderer/WindowContentRenderer.swift` — semantic row to attributed string, CoreText rasterization, texture and atlas upload path.
- `macos/Sources/Renderer/BitmapRasterizer.swift` — pooled CoreGraphics/CoreText bitmap rasterization.
- `macos/Sources/Renderer/LineTextureAtlas.swift`, `macos/Sources/Renderer/SlotAllocator.swift`, `macos/Sources/Renderer/CachedLineTexture.swift` — atlas allocation, cache hits, and uploads.
- `macos/Sources/Renderer/CoreTextMetalRenderer.swift` — frame render loop that calls `WindowContentRenderer`, line instance construction, overlay quads, and Metal draw setup when benchmark work points there.
- `macos/Sources/Font/FontFace.swift`, `macos/Sources/Font/FontManager.swift` — font lookup and per-span font selection hot paths.
- `macos/Sources/Protocol/ProtocolDecoder.swift`, `macos/Sources/Renderer/CommandDispatcher.swift`, `macos/Sources/Renderer/WindowContent.swift` — semantic content decode and state update path when benchmark work points there.
- `bench/swift_render_bench.swift`, `autoresearch.sh`, `autoresearch.checks.sh` — benchmark and validation harness.

## Off Limits
- Do not change public protocol wire formats unless a benchmark result clearly requires it and tests/docs are updated in the same kept experiment.
- Do not skip rasterization, atlas upload, cache invalidation, or semantic content correctness to win the benchmark.
- Do not make the Swift frontend interpret editor semantics; the BEAM remains the source of truth.
- Do not add new dependencies for micro-optimizations.
- Do not use private AppKit, CoreText, or Metal APIs.

## Constraints
- Primary metric decides keep/discard. Keep only lower `swift_frame_us` unless a secondary metric exposes a correctness or catastrophic regression.
- `./autoresearch.checks.sh` must pass before keeping any code change.
- Preserve user-visible rendering behavior: text, styles, font fallback, cache invalidation, and atlas contents must remain correct.
- Prefer structural hot-path reductions: fewer attributed-string allocations, fewer CoreText objects, better cache reuse, less atlas churn, less per-row work on cache hits.

## What's Been Tried
- Switched from the headless BEAM keystroke benchmark after reaching about 1.8ms p50 internally. New target focuses on macOS Swift semantic rendering.
