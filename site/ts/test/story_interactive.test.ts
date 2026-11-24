import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  applyTypedChar,
  computeStagedSnapshot,
  createIsolationSimState,
  createStagedPipelineState,
  tickIsolationSim,
  triggerIsolationFault,
} from "../src/arch_interactive.ts";
import { EXTENDING_SCENARIOS } from "../src/extending_interactive.ts";
import { highlightElixirLine } from "../src/highlight.ts";
import { createHeroTourState, handleHeroTourKey, reduceHeroTour } from "../src/home_interactive.ts";

describe("Homepage playable Feature Tour state machine", () => {
  it("undoes only the human edit while preserving braided Twist, then keeps cleanly", () => {
    let s = createHeroTourState();
    assert.equal(s.userEditPresent, true);
    s = reduceHeroTour(s, { type: "undo_yours" });
    assert.equal(s.userEditPresent, false);
    assert.equal(s.twistStatus, "unreviewed");
    s = reduceHeroTour(s, { type: "keep_twist" });
    assert.equal(s.twistStatus, "kept");
  });

  it("steps Subagent Peek siblings while preserving parent draft and reorders queue", () => {
    let s = createHeroTourState();
    s = reduceHeroTour(s, { type: "set_draft", text: "Keep this unsent draft" });
    s = reduceHeroTour(s, { type: "peek_step", delta: 1 });
    assert.equal(s.peekIndex, 2);
    assert.equal(s.parentDraft, "Keep this unsent draft");

    const topBefore = s.queueItems[0];
    s = reduceHeroTour(s, { type: "queue_swap" });
    assert.equal(s.queueItems[1], topBefore);

    s = reduceHeroTour(s, { type: "approve", choice: "y" });
    assert.equal(s.approvalState, "approved_once");
  });

  it("handles real keyboard chords across Feature Tour tabs (SPC a y, ]], za, y, dd, p, o)", () => {
    let s = createHeroTourState();
    let res = handleHeroTourKey(s, "panel-spec-twist", "", "u");
    assert.equal(res.handled, true);
    assert.equal(res.state.userEditPresent, false);

    res = handleHeroTourKey(res.state, "panel-spec-twist", "", " ");
    assert.equal(res.pending, "SPC");
    res = handleHeroTourKey(res.state, "panel-spec-twist", res.pending, "a");
    assert.equal(res.pending, "SPC a");
    res = handleHeroTourKey(res.state, "panel-spec-twist", res.pending, "y");
    assert.equal(res.state.twistStatus, "kept");

    res = handleHeroTourKey(res.state, "panel-spec-tasks", "", "y");
    assert.equal(res.state.approvalState, "approved_once");

    const lenBefore = res.state.queueItems.length;
    res = handleHeroTourKey(res.state, "panel-spec-tasks", "", "d");
    res = handleHeroTourKey(res.state, "panel-spec-tasks", res.pending, "d");
    assert.equal(res.state.queueItems.length, lenBefore - 1);

    res = handleHeroTourKey(res.state, "panel-spec-tasks", "", "o");
    assert.equal(res.state.queueItems.length, lenBefore);
  });
});

describe("Architecture live typing fault simulator & staged overlay pipeline", () => {
  it("freezes single-loop keystrokes during LSP hang while Minga types live, then flushes on unblock", () => {
    let sim = createIsolationSimState();
    const initial = sim.mingaText;
    sim = triggerIsolationFault(sim, "lsp_hang");
    sim = applyTypedChar(sim, `${initial} # ok`);
    assert.equal(sim.mingaText, `${initial} # ok`);
    assert.equal(sim.legacyText, initial);
    assert.equal(sim.legacyQueued, " # ok");

    sim = tickIsolationSim(sim, 3000);
    assert.equal(sim.fault, "none");
    assert.equal(sim.legacyText, `${initial} # ok`);
    assert.equal(sim.legacyQueued, "");
  });

  it("kills in-process editor on parser crash while Minga respawns Zig port and restores colors", () => {
    let sim = createIsolationSimState();
    sim = triggerIsolationFault(sim, "parser_crash");
    assert.equal(sim.legacyDead, true);
    assert.equal(sim.mingaParserPlain, true);
    sim = tickIsolationSim(sim, 700);
    assert.equal(sim.mingaParserPlain, false);
    assert.equal(sim.legacyDead, true);
  });

  it("renders clean 3-way merge and conflict states cleanly with Elixir highlighting", () => {
    const cleanPublish = computeStagedSnapshot({ ...createStagedPipelineState(), step: 4, conflictMode: false });
    assert.equal(cleanPublish.diskStatus.label, "Modified retry.ex");

    const conflictPublish = computeStagedSnapshot({ ...createStagedPipelineState(), step: 4, conflictMode: true });
    assert.equal(conflictPublish.diskStatus.label, "Clean (publish paused)");
    assert.equal(conflictPublish.overlayStatus.tone, "fail");

    const highlighted = highlightElixirLine('def foo, do: :ok # hi');
    assert.match(highlighted, /class="ckw">def<\/span>/);
    assert.match(highlighted, /class="cat">:ok<\/span>/);
    assert.match(highlighted, /class="ccm"># hi<\/span>/);
    assert.ok(EXTENDING_SCENARIOS.migration.layers[3].code.includes("tuesday_migration_audit"));
  });
});
