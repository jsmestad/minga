import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { ISOLATION_VIEWS, STAGED_VIEW_KEYS } from "../src/arch_interactive.ts";
import { readPageLab } from "./support/page_copy.ts";

/* The Architecture demos read their copy from the page by key. This test fails when the page and the keys in the script drift apart. */

const faultLab = readPageLab("architecture.html", "data-arch-fault-map");
const stepperLab = readPageLab("architecture.html", "data-staged-stepper");
const faultDemo = faultLab.html;
const stepper = stepperLab.html;

describe("Architecture page contract", () => {
  it("has exactly one step of copy for every fault view", () => {
    assert.deepEqual([...faultLab.steps].sort(), [...ISOLATION_VIEWS].sort());
  });

  it("has exactly one step of copy for every stepper view", () => {
    assert.deepEqual([...stepperLab.steps].sort(), [...STAGED_VIEW_KEYS].sort());
  });

  it("only shows fault elements for views the script can reach", () => {
    const tokens = faultLab.attr("data-iso-show").flatMap((v) => v.split(/\s+/));
    assert.ok(tokens.length > 0);
    for (const token of tokens) assert.ok((ISOLATION_VIEWS as readonly string[]).includes(token), token);
  });

  it("only shows stepper elements for views the script can reach", () => {
    const tokens = stepperLab.attr("data-st-show").flatMap((v) => v.split(/\s+/));
    assert.ok(tokens.length > 0);
    for (const token of tokens) assert.ok((STAGED_VIEW_KEYS as readonly string[]).includes(token), token);
  });

  it("keeps the demo controls hidden until the script mounts", () => {
    assert.match(faultDemo, /data-iso-controls hidden/);
    assert.match(stepper, /data-st-controls hidden/);
  });
});
