# Highlighted scroll preparation

Reusing highlight span identities removes two full-document hashes from unchanged parser-highlighted frames. In three alternating baseline/candidate pairs, median synchronous preparation time for 65,000 lines fell from 80.673 ms to 7.076 ms (91.2% lower). Every measured scroll frame reused its text rows.

| Document lines | Content p50, baseline | Content p50, candidate | Preparation p50, baseline | Preparation p50, candidate | Preparation p95, baseline | Preparation p95, candidate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500 | 0.581 ms | 0.024 ms | 0.731 ms | 0.154 ms | 0.819 ms | 0.194 ms |
| 5,000 | 5.697 ms | 0.023 ms | 6.333 ms | 0.572 ms | 6.468 ms | 0.650 ms |
| 65,000 | 73.474 ms | 0.062 ms | 80.673 ms | 7.076 ms | 84.415 ms | 7.475 ms |

Each table value is the median of three run-specific percentiles, not a percentile of pooled samples. [All six runs and environment details](comparison.json) retain the individual results, including the 8.948 ms candidate preparation p95 in the second pair.

## What changed

The content cache and resident-row builder previously hashed the entire Highlight struct, including every syntax span. The new fingerprint uses an identity assigned when spans are accepted, plus the existing version, capture names, theme, face registry, and parser correlation. Accepted equal-version or identical span replacements conservatively invalidate once; stale updates preserve the old identity. Assigning a stored identity does not hash the document on the Editor process.

Semantic composition uses a digest of the final remapped and sorted spans so equivalent compositions produce stable fingerprints. That composition still traverses document spans and is outside this fixture.

## Reproduction

Use the dependencies and test build for each revision. From the candidate checkout, run:

```sh
MIX_ENV=test mix run bench/highlight_scroll_bench.exs
```

For a comparison, prepare a second checkout at baseline `a04cd31e0198ebbb31bb4421a259f645a117c36f`, then run the same candidate benchmark file against both checkouts. From each checkout, set `BENCHMARK` to the absolute path of the candidate's `bench/highlight_scroll_bench.exs` and run:

```sh
MIX_ENV=test mix run "$BENCHMARK"
```

Run the pairs in baseline/candidate, candidate/baseline, baseline/candidate order. Keep builds and other benchmark runs sequential. The recorded runs used Apple M3 Pro, macOS 26.6.2, Elixir 1.20.4, and Erlang/OTP 29.0.6.

The fixture is an unnamed, untracked, unwrapped buffer with seven deterministic parser spans per line, a 40-row by 100-column viewport, and full resident-row storage. It excludes asynchronous parser work. Each run prepares three frames, alternates three-row scrolls in both directions, discards ten scroll warmups, and measures sixty frames. The benchmark fails if any measured frame recomposes a text row.

Durations come from telemetry spans. `content_*` measures `Content.build_content/2`. `frame_*` measures synchronous cursor bookkeeping, intent/status-bar construction, buffer preparation, layout, scroll calculation, content construction, renderer commit, and receipt integration. The renderer state is carried between frames.

## Measurement limits

These are warm preparation measurements. They exclude mouse-event handling, mailbox queueing, frontend protocol transport, decoding, Metal drawing, and display presentation. They do not establish input-to-pixel latency, a sustained display rate, or parity with another editor.

The remaining preparation time includes the existing full-document merge-conflict scan for untracked buffers in status-bar construction. Git-tracked buffers use a cached conflict count. Semantic tokens, wrapping, folding, cold rendering, and highlight replacement workloads need separate measurements.
