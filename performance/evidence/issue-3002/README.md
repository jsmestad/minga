# Native resource lifetime investigation for issue #3002

This directory retains the raw Release-path measurements that promoted and verified the focused `LineTextureAtlas` generation ring. The evidence rejects both the shipping whole-atlas CPU copy and the smaller whole-atlas GPU blit. It does not justify a generic frame-resource pool.

## Method

The `NativeRenderPerformance` executable exercises the production `CoreTextMetalRenderer` in Release with `-O`, `MINGA_SNAPSHOT_RENDERER`, and `MINGA_TRANSCRIPT_ACCOUNTING`. Every steady workload warms the renderer before retaining 31 per-frame samples. The keyframe workload retains seven samples and cold start retains one. Each result below is the median value from three independent batches.

All batches ran on an Apple M1 with 16 GiB physical memory and macOS 26.6.1 (25G76), with nominal thermal state. The baseline batches ran with low-power mode disabled. The full-GPU-copy and atlas-ring batches ran with low-power mode enabled. Therefore, the baseline-to-correction wall-time values are not a strict paired comparison. The mechanism and absolute promotion decision remain auditable: the baseline directly counts full-atlas CPU copies and fails the established limits, while the two correction alternatives use equivalent low-power and thermal conditions and are compared against the same absolute gates. The final atlas-ring batches were collected only after other local Xcode builds had stopped. Noisy concurrent-build batches were discarded and are not included.

The ordinary-frame acceptance limits are CPU p95 at or below 2.5 ms, CPU p99 at or below 4 ms, GPU p95 at or below 8.33 ms, and completion-wall p95 at or below 8.33 ms. Warm frames must allocate no Metal textures or buffers, retain at most three in-flight generations, visit no more than visible rows plus overscan, and drop no frames. Keyframe and cold-start samples characterize cold and growth behavior; they are not ordinary-frame gate inputs.

## Alternatives

| Alternative | Result | Reason |
| --- | --- | --- |
| Current failure-atomic candidate with CPU whole-atlas copy | Reject | A one-row edit copies 19,566,848 atlas bytes per frame while uploading about 14.4 KiB of changed raster. It fails CPU and completion-wall limits. |
| Focused whole-atlas Metal blit | Reject | It restores CPU latency, but transfer cost scales with atlas capacity. The 4-pane and 8-pane one-row workloads fail the completion-wall limit. |
| Three-generation `LineTextureAtlas` ring | Accept | It uploads only changed slots, allocates nothing after warm-up, removes steady full-atlas copies, satisfies all ordinary one-row limits, and preserves bounded failure-atomic publication. |
| Generic frame-resource pool | Reject | Existing warm render targets and buffers already allocate nothing. A generic pool does not address the measured atlas-copy blocker. |
| Unbounded or globally owned caches | Reject | They do not provide an auditable memory or in-flight lifetime bound and can permit mutation of visible or in-flight resources. |

## Measured decision path

Median of the three baseline batches:

| Workload | CPU p95 | CPU p99 | GPU p95 | Wall p95 | Atlas copy bytes per batch | Raster upload bytes | Warm texture allocations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| One-row edit, 1 pane | 8.659 ms | 11.967 ms | 2.202 ms | 11.860 ms | 606,572,288 | 446,336 | 31 |
| 8-pane atlas-miss pressure | 24.383 ms | 29.803 ms | 2.643 ms | 34.031 ms | 1,869,435,904 | 3,675,200 | 31 |
| Keyframe growth | 10.171 ms | 10.171 ms | 2.250 ms | 12.328 ms | 117,401,088 | 9,916,928 | 8 |

The baseline revision is `2a0df44a34849081d4230ed6c884fa71637c665d`. The baseline harness did not yet include fixed-one-row 4-pane and 8-pane workloads. It directly establishes the one-pane copy mechanism and the 8-pane pressure scaling. The next two alternatives add the fixed dirty-row capacity comparison.

Median of the three focused whole-atlas GPU-copy batches:

| Workload | CPU p95 | CPU p99 | GPU p95 | Wall p95 | Atlas copy bytes per batch | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| One-row edit, 1 pane | 0.923 ms | 0.924 ms | 2.756 ms | 6.563 ms | 604,086,336 | Pass |
| One-row edit, 4 panes | 1.105 ms | 1.421 ms | 4.096 ms | 9.342 ms | 1,031,670,080 | Fail wall |
| One-row edit, 8 panes | 1.572 ms | 1.853 ms | 3.151 ms | 12.153 ms | 1,866,949,952 | Fail wall |
| 8-pane atlas-miss pressure | 1.743 ms | 2.234 ms | 2.745 ms | 11.932 ms | 1,849,548,288 | Pressure only |

The whole-atlas GPU-copy result is an intermediate working-tree experiment based on `2a0df44a34849081d4230ed6c884fa71637c665d`. It is retained as raw evidence but is not a separately addressable commit.

Median of the three accepted atlas-ring batches at implementation revision `b8082153b34541923ef455b88e500835fb50dee6`:

| Workload | CPU p95 | CPU p99 | GPU p95 | Wall p95 | Atlas copy bytes | Raster upload bytes | Warm allocations | Retained native bytes | Result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| One-row edit, 1 pane | 0.791 ms | 0.968 ms | 2.002 ms | 3.834 ms | 0 | 446,336 | 0 | 86,366,592 | Pass |
| One-row edit, 4 panes | 1.318 ms | 1.335 ms | 2.036 ms | 5.526 ms | 0 | 446,336 | 0 | 127,763,136 | Pass |
| One-row edit, 8 panes | 2.015 ms | 2.026 ms | 2.113 ms | 6.066 ms | 0 | 446,336 | 0 | 208,632,192 | Pass |
| 8-pane atlas-miss pressure | 2.740 ms | 2.831 ms | 2.082 ms | 7.322 ms | 0 | 3,675,200 | 0 | 208,632,192 | Pressure only |

All accepted batches visited exactly the visible-row-plus-overscan bound: 82 rows for one pane, 168 for four panes, and 336 for eight panes. They dropped zero frames and recorded no warm texture or buffer allocations. The probe observed one submitted generation at a time in this serial harness, below the implementation limit of three. Focused concurrency tests separately exercise the three-generation bound and late completion ordering.

The accepted ring retains three physical atlas generations. Peak retained native bytes rise from the single-generation baseline to 86,366,592 bytes for one pane, 127,763,136 bytes for four panes, and 208,632,192 bytes for eight panes. This is the explicit bounded memory tradeoff for eliminating steady full-atlas copies. Issue #2999 limits in-flight generation count and requires recorded bounded bytes; it does not define a separate native-byte ceiling.

## Workloads and counters

- `cold_start` measures the first frame with an empty renderer.
- `idle_redraw`, `cursor_blink_60hz`, `cursor_blink_120hz`, `local_scroll_60hz`, and `local_scroll_120hz` exercise stable warm content.
- `one_row_edit`, `one_row_edit_panes_4`, and `one_row_edit_panes_8` change exactly one visible row per frame while varying atlas capacity.
- `keyframe` submits full-refresh content with changing epochs and layout generations to exercise growth and replacement.
- `panes_1`, `panes_4`, and `panes_8` measure warm steady-state capacity scaling.
- `atlas_miss_resource_pressure` changes one visible row in each of eight panes per frame.

Each JSON workload contains raw frame samples plus CPU, GPU, and completion-wall p50/p95/p99; allocation counts and bytes; candidate counts; atlas growth and stable-copy bytes; raster upload bytes; maximum rows visited; generation counts; dropped frames; retained native bytes; process resident memory; and environment metadata.

## Reproduction

Build and run the investigation harness from the repository root:

```sh
xcodebuild build -project macos/Minga.xcodeproj -scheme NativeRenderPerformance -configuration Release -derivedDataPath /private/tmp/minga-native-build CODE_SIGNING_ALLOWED=NO 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=MINGA_SNAPSHOT_RENDERER MINGA_TRANSCRIPT_ACCOUNTING'
scripts/check_native_render_performance --investigate /private/tmp/minga-native-build /private/tmp/minga-native-resource-run.json
```

Run three independent batches under stable thermal and host-load conditions. Use the raw per-frame samples for diagnosis and the median of matching aggregate values for the decision tables.

## Artifact checksums

```text
ef72b7013a3c2133e8c7d41fdfacf8519e13c04232d75ac38fb85293fafbb2de  atlas-ring-run-1.json.gz
43612953d76ff3acbe1887a2d0db950ef4ec62748e33f8275ca689f427d61694  atlas-ring-run-2.json.gz
b14a70cf48e1efaafe3aec727b39fd03f2c35241efa81e70fdb89bdd354aae5c  atlas-ring-run-3.json.gz
f45fde2643af5218989cbdc1aff7fdb80e26bd73581ca0a3dab2bcd1a337856f  baseline-cpu-copy-run-1.json.gz
5109cdcd191203f4dec3665a913690f994315a8734ac4c9afce5e23137aea7d0  baseline-cpu-copy-run-2.json.gz
05c851bbb49ef02c88fe9f747e646523c087a1a44a7a052ad7a8eff2b96577c1  baseline-cpu-copy-run-3.json.gz
914dd489afddf47da5de37375aae1fa3ded0d8eba3047c2cdfd1d1eb5c4a7cc6  full-gpu-copy-run-1.json.gz
fca44f8e2a42e8fb6229bbeed9f7c6d4f43ed17a061ffebc0e3786345dea61db  full-gpu-copy-run-2.json.gz
c46f0f5174f4a33c9cd959c646cefb773cec353ac0e6cda0bbbb764d7d7f20f0  full-gpu-copy-run-3.json.gz
```
