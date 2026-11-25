import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  ISOLATION_BASE_LINE,
  ISOLATION_TYPED,
  applyTypedChar,
  applyTypedText,
  computeStagedSnapshot,
  createIsolationSimState,
  createStagedPipelineState,
  faultButtonLabel,
  finishIsolationFault,
  stepStagedPipeline,
  tickIsolationSim,
  triggerIsolationFault,
} from "../src/arch_interactive.ts";
import { highlightElixirLine } from "../src/highlight.ts";

describe("Architecture fault simulation & staged edit stepper", () => {
  it("queues same-loop keys while the language server is slow, and Minga draws each one", () => {
    let sim = triggerIsolationFault("slow_server");
    assert.equal(sim.view, "slow-during");
    sim = applyTypedText(sim, ISOLATION_TYPED);
    assert.equal(sim.mingaText, ISOLATION_BASE_LINE + ISOLATION_TYPED);
    assert.equal(sim.legacyText, ISOLATION_BASE_LINE);
    assert.equal(sim.legacyQueued, ISOLATION_TYPED.length);

    sim = tickIsolationSim(sim, 2900);
    assert.equal(sim.view, "slow-during");
    sim = tickIsolationSim(sim, 100);
    assert.equal(sim.view, "slow-after");
    assert.equal(sim.legacyText, sim.mingaText);
    assert.equal(sim.legacyQueued, 0);
  });

  it("ends the same-loop editor on a parser crash while Minga keeps the text and the keys", () => {
    let sim = triggerIsolationFault("parser_crash");
    assert.equal(sim.legacyDead, true);
    assert.equal(sim.view, "crash-during");
    sim = applyTypedChar(sim, "x");
    assert.equal(sim.mingaText, `${ISOLATION_BASE_LINE}x`);
    assert.equal(sim.legacyText, "");
    sim = finishIsolationFault(sim);
    assert.equal(sim.view, "crash-after");
    assert.equal(sim.legacyDead, true);
    assert.equal(sim.mingaText, `${ISOLATION_BASE_LINE}x`);
  });

  it("starts every fault from a fresh line and steps instead of counting down under reduced motion", () => {
    const rest = createIsolationSimState();
    assert.equal(faultButtonLabel(rest, "slow_server", false), "start");

    const running = triggerIsolationFault("slow_server");
    assert.equal(faultButtonLabel(running, "slow_server", false), "start");
    assert.equal(faultButtonLabel(running, "slow_server", true), "next");
    assert.equal(faultButtonLabel(running, "parser_crash", true), "start");

    const done = finishIsolationFault(applyTypedText(running, ISOLATION_TYPED));
    assert.equal(faultButtonLabel(done, "slow_server", true), "again");
    assert.equal(triggerIsolationFault("slow_server").mingaText, ISOLATION_BASE_LINE);
  });

  it("offers Run again when a run has ended, with or without reduced motion", () => {
    const done = finishIsolationFault(triggerIsolationFault("slow_server"));
    assert.equal(faultButtonLabel(done, "slow_server", false), "again");
    assert.equal(faultButtonLabel(done, "parser_crash", false), "start");
  });

  it("ignores ticks once a run has ended, and draws later keys in both editors", () => {
    const done = finishIsolationFault(applyTypedText(triggerIsolationFault("slow_server"), ISOLATION_TYPED));
    assert.deepEqual(tickIsolationSim(done, 5000), done);

    const later = applyTypedChar(done, "!");
    assert.equal(later.legacyText, `${ISOLATION_BASE_LINE}${ISOLATION_TYPED}!`);
    assert.equal(later.legacyText, later.mingaText);
    assert.equal(later.legacyQueued, 0);
  });

  it("shows the conflict choice changing nothing in steps 1 and 2", () => {
    for (const step of [1, 2] as const) {
      assert.deepEqual(computeStagedSnapshot({ step, conflictMode: true }), computeStagedSnapshot({ step, conflictMode: false }));
    }
    assert.notDeepEqual(computeStagedSnapshot({ step: 3, conflictMode: true }), computeStagedSnapshot({ step: 3, conflictMode: false }));
    assert.notDeepEqual(computeStagedSnapshot({ step: 4, conflictMode: true }), computeStagedSnapshot({ step: 4, conflictMode: false }));
  });

  it("keeps line numbers the same in every step and shows the replaced line as removed", () => {
    const views = [1, 2, 3, 4].flatMap((step) =>
      [false, true].map((conflictMode) => computeStagedSnapshot({ step: step as 1 | 2 | 3 | 4, conflictMode })),
    );
    for (const snap of views) {
      assert.deepEqual([...new Set(snap.rows.map((r) => r.ln))], [12, 13, 14, 15], snap.view);
    }

    const staged = computeStagedSnapshot({ step: 2, conflictMode: false });
    assert.deepEqual(staged.rows.slice(0, 2).map((r) => [r.ln, r.kind]), [[12, "del"], [12, "add"]]);

    const published = computeStagedSnapshot({ step: 4, conflictMode: false });
    assert.deepEqual(published.rows.map((r) => r.kind), ["add", "normal", "normal", "you"]);

    const stopped = computeStagedSnapshot({ step: 4, conflictMode: true });
    assert.deepEqual(stopped.rows.slice(0, 2).map((r) => [r.ln, r.kind]), [[12, "you"], [12, "add"]]);
  });

  it("steps forward and back, stays on step 1 going back, and starts over after step 4", () => {
    let st = createStagedPipelineState();
    assert.equal(stepStagedPipeline(st, "back").step, 1);
    st = stepStagedPipeline(stepStagedPipeline(st, "next"), "next");
    st = { ...st, conflictMode: true };
    assert.equal(computeStagedSnapshot(st).view, "3-conflict");
    st = stepStagedPipeline(st, "next");
    assert.equal(computeStagedSnapshot(st).view, "4-conflict");
    assert.equal(stepStagedPipeline(st, "back").step, 3);
    assert.deepEqual(stepStagedPipeline(st, "next"), createStagedPipelineState());
  });

  it("renders Elixir highlighting", () => {
    const highlighted = highlightElixirLine('def foo, do: :ok # hi');
    assert.match(highlighted, /class="ckw">def<\/span>/);
    assert.match(highlighted, /class="cat">:ok<\/span>/);
    assert.match(highlighted, /class="ccm"># hi<\/span>/);
  });
});
