# Rendering performance gates

The macOS renderer has two independent production gates: deterministic work-count gates (completed as their resident-rendering dependencies land) and an optimized native wall-clock gate. Wall-clock numbers diagnose native preparation; they do not replace deterministic complexity assertions.

## Optimized native harness

Run:

```sh
scripts/check_render_performance
```

The script always compiles `macos/Tests/Performance/main.swift` with `swiftc -O`. It warms the fixed `native-visible-v1` fixture for 200 iterations, measures 1,000 iterations, and prints p50/p95 for:

- protocol-shaped decode plus semantic application;
- visible-range command preparation;
- the combined preparation path.

The checked-in, versioned references are in `performance/baselines/macos_render_release.json`. Production policy is hard-coded in `RenderPerformanceGate`: each stage must be at or below **4.00 ms p95**, the combined path at or below **8.00 ms p95**, and each value at or below **1.20x** its reference. The JSON schema deliberately has no policy fields, so a baseline update cannot relax those ceilings. The comparator treats each exact boundary as passing and the next representable value as failing.

The `native-visible-v1` references were calibrated on 2026-07-12 using the GitHub-hosted `macos-15` arm64 runner on macOS 15.7.7 (24G720), its default Xcode toolchain, and `swiftc -O`. After 200 warmups and 1,000 measured iterations, CI run `29176725578` reported p95 references of **0.762125 ms decode/apply**, **0.026 ms command preparation**, and **1.362917 ms combined**. Calibrating on the enforced CI environment makes the 20 percent regression policy meaningful where it runs, while the hard-coded 4 ms stage and 8 ms combined ceilings remain unchanged.

Baseline changes are never generated in CI. A baseline change must include the explicit JSON diff plus provenance and a PR rationale naming the fixture/toolchain change and measurements that justify it. Unsupported schema versions or fixtures and non-finite/non-positive references or measurements fail closed.

## Native latency milestones

`LatencyRecorder` tracks these milestones separately:

1. input received (`stamp`);
2. frontend semantic state applied (`markApplied`);
3. Metal command buffer submitted (`markSubmitted`);
4. successful command-buffer completion after a drawable was scheduled (`markPresented`).

GPU completion is the closest reliable native callback currently used; it is later and more honest than semantic apply, but is not a claim about photon timing. Screen-sleep, hidden, occluded, nil-drawable, superseded, scheduling-impossible, renderer-dropped, and GPU-failed samples are discarded with typed reasons. Hidden and occluded surfaces are rejected before drawable acquisition or presentation-sequence selection, so a retained occluded drawable cannot resolve as presented. The HUD labels `apply` and `present` separately. A frame acknowledgement updates apply only and cannot resolve presentation.

## #2743 remaining integration ledger

The following acceptance work is deliberately **not** implemented by this dependency-independent slice:

- **AC 1:** production conformance corpus for sections larger than 65,535 bytes, the 65,536-line resident document, structural edits near row zero, reference misses, stale content epochs/generations, and reset recovery across BEAM/Swift/Go. This requires #2740 content epochs and #2741 resident storage.
- **AC 2:** final deterministic ordinary-edit counters and limits: zero resets, exactly one ChangeLog consumption, at most eight lines fetched/composed, at most four Swift chunks touched, visible-plus-overscan rows visited, and separate decoration work. This requires #2741 and #2742.
- **AC 3:** 256 KiB request/receipt assertions on the 65,536-line fixture. This requires the resident-store fixture and renderer-owned measurement points from #2741/#2742.
- **AC 4:** replace the independent fixed benchmark fixture's semantic store/preparation operations with the final #2740-#2742 production resident decode/apply and renderer command-preparation path while retaining this harness, percentile, baseline, and comparator framework.
- **AC 5:** add a distinct BEAM-frame-emitted timestamp if the cross-process protocol gains that milestone; this slice covers native receipt/apply/submission/completion and discard semantics.
- **AC 6:** wire the final deterministic complexity and message-size gates after their counters and corpus exist. The optimized absolute/relative native gate is wired now.
- **AC 7:** presentation labels and non-resolution from apply are complete; final overlay-specific consumption should be checked with #2735 when that work lands.

Do not satisfy this ledger with placeholder counters, synthetic 65,536-row assertions, or stale-epoch fixtures that bypass the owning dependency implementations.
