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
import { highlightElixirLine } from "../src/highlight.ts";

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
  });
});
