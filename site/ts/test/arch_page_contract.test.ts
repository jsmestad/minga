import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { ISOLATION_VIEWS, STAGED_VIEW_KEYS } from "../src/arch_interactive.ts";

/* The Architecture demos read their copy from the page by key. This test fails when the page and the keys in the script drift apart. */

const page = readFileSync(new URL("../../architecture.html", import.meta.url), "utf8");

function attrValues(html: string, attr: string): string[] {
  return Array.from(html.matchAll(new RegExp(`\\b${attr}="([^"]*)"`, "g")), (m) => m[1]!);
}

/** The markup of the element that carries `marker`, up to the next demo or the end of the article. */
function demoMarkup(marker: string, nextMarker: string): string {
  const start = page.indexOf(marker);
  assert.notEqual(start, -1, `${marker} is not in the page`);
  const end = page.indexOf(nextMarker, start + marker.length);
  return page.slice(start, end === -1 ? undefined : end);
}

const faultDemo = demoMarkup("data-arch-fault-map", "data-staged-stepper");
const stepper = demoMarkup("data-staged-stepper", "</article>");

describe("Architecture page contract", () => {
  it("has exactly one step of copy for every fault view", () => {
    assert.deepEqual(attrValues(faultDemo, "data-step").sort(), [...ISOLATION_VIEWS].sort());
  });

  it("has exactly one step of copy for every stepper view", () => {
    assert.deepEqual(attrValues(stepper, "data-step").sort(), [...STAGED_VIEW_KEYS].sort());
  });

  it("only shows fault elements for views the script can reach", () => {
    const tokens = attrValues(faultDemo, "data-iso-show").flatMap((v) => v.split(/\s+/));
    assert.ok(tokens.length > 0);
    for (const token of tokens) assert.ok((ISOLATION_VIEWS as readonly string[]).includes(token), token);
  });

  it("only shows stepper elements for views the script can reach", () => {
    const tokens = attrValues(stepper, "data-st-show").flatMap((v) => v.split(/\s+/));
    assert.ok(tokens.length > 0);
    for (const token of tokens) assert.ok((STAGED_VIEW_KEYS as readonly string[]).includes(token), token);
  });

  it("keeps the demo controls hidden until the script mounts", () => {
    assert.match(faultDemo, /data-iso-controls hidden/);
    assert.match(stepper, /data-st-controls hidden/);
  });
});
