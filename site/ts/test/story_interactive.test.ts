import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  computeStagedSnapshot,
  createArchFaultState,
  createStagedPipelineState,
  toggleArchFault,
} from "../src/arch_interactive.ts";
import { createRollbackDemoState, reduceRollbackDemo } from "../src/extending_interactive.ts";
import { createHeroTourState, reduceHeroTour } from "../src/home_interactive.ts";

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
});

describe("Architecture fault simulator & staged overlay pipeline", () => {
  it("isolates Zig parser and MCP faults while recording supervisor traces", () => {
    let f = createArchFaultState();
    f = toggleArchFault(f, "parser");
    assert.equal(f.parserCrashed, true);
    assert.match(f.log[0] ?? "", /minga-parser/);
    f = toggleArchFault(f, "mcp");
    assert.equal(f.mcpCrashed, true);
    assert.match(f.log[0] ?? "", /GitHub MCP/);
  });

  it("merges non-overlapping edits cleanly and pauses on overlapping conflict", () => {
    const cleanPublish = computeStagedSnapshot({ ...createStagedPipelineState(), step: 4, conflictMode: false });
    assert.equal(cleanPublish.diskBadge, "published");
    assert.match(cleanPublish.headline, /Clean 3-way merge/);

    const conflictPublish = computeStagedSnapshot({ ...createStagedPipelineState(), step: 4, conflictMode: true });
    assert.equal(conflictPublish.diskBadge, "clean");
    assert.match(conflictPublish.headline, /conflict review/);

    const recovered = computeStagedSnapshot({ step: 3, conflictMode: false, crashedAndRecovered: true });
    assert.match(recovered.overlayBadge, /Recovered/);
  });
});

describe("Extending Layer 3 save-to-activate & rollback safety demo", () => {
  it("requires explicit grant before activation and auto-restores Gen #2 on broken Gen #3", () => {
    let s = createRollbackDemoState();
    s = reduceRollbackDemo(s, "activate");
    assert.equal(s.stage, "draft");
    assert.match(s.errorDetail, /requires an explicit revocable session grant/);

    s = reduceRollbackDemo(s, "grant");
    assert.equal(s.grantActive, true);
    s = reduceRollbackDemo(s, "activate");
    assert.equal(s.stage, "active");
    assert.equal(s.activeGeneration, 2);

    s = reduceRollbackDemo(s, "inject_failure");
    assert.equal(s.stage, "rolled_back");
    assert.equal(s.activeGeneration, 2);
    assert.match(s.errorDetail, /Automatically restored Generation #2/);

    s = reduceRollbackDemo(s, "discard");
    assert.equal(s.stage, "discarded");
    assert.equal(s.grantActive, false);
  });
});
