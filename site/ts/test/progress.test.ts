import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { STEP_IDS } from "../src/coauthor_state.ts";
import { LESSON_STEPS, summarizeLesson } from "../src/progress.ts";
import { SANDBOX_MISSIONS } from "../src/sandbox_state.ts";
import { STEP_IDS as VETO_STEP_IDS } from "../src/veto_state.ts";

describe("lesson progress: only a lesson's current ids count", () => {
  /** What a visitor who finished the old Lesson 03 simulator has in storage. */
  const OLD_AGENTS = ["per_author_undo", "lockout_guard", "subagent_peek", "review_change"];

  const table: readonly { name: string; stored: unknown; lesson: string; done: number; total: number }[] = [
    { name: "an empty store", stored: {}, lesson: "agents", done: 0, total: 4 },
    { name: "only ids from the old lab", stored: { agents: OLD_AGENTS }, lesson: "agents", done: 0, total: 4 },
    { name: "old and current ids mixed", stored: { agents: [...OLD_AGENTS, "find", "reject"] }, lesson: "agents", done: 2, total: 4 },
    { name: "every current id, with old ids beside them", stored: { agents: [...STEP_IDS, ...OLD_AGENTS] }, lesson: "agents", done: 4, total: 4 },
    { name: "an id stored twice", stored: { agents: ["find", "find"] }, lesson: "agents", done: 1, total: 4 },
    { name: "another lesson's ids", stored: { editing: ["which_key"], agents: ["which_key"] }, lesson: "agents", done: 0, total: 4 },
    { name: "a lesson the site no longer has", stored: { "getting-started": ["configured"] }, lesson: "getting-started", done: 0, total: 0 },
    { name: "a lesson the site does not have", stored: { advanced: ["a", "b"] }, lesson: "advanced", done: 0, total: 0 },
    { name: "an unknown lesson stored beside a real one", stored: { advanced: ["a"], remote: ["blocked"] }, lesson: "remote", done: 1, total: 3 },
    { name: "a name every object has is not a lesson", stored: {}, lesson: "toString", done: 0, total: 0 },
    { name: "a stored value that is not a list", stored: { agents: "find" }, lesson: "agents", done: 0, total: 4 },
    { name: "a store that is not an object", stored: null, lesson: "agents", done: 0, total: 4 },
  ];

  for (const row of table) {
    it(row.name, () => {
      assert.deepEqual(summarizeLesson(row.stored, row.lesson), { done: row.done, total: row.total });
    });
  }
});

describe("lesson progress: the list and the labs agree", () => {
  it("Lesson 03 records exactly the ids the list holds", () => {
    assert.deepEqual(LESSON_STEPS.agents, STEP_IDS);
  });

  it("Lesson 05 records exactly the ids the list holds", () => {
    assert.deepEqual(LESSON_STEPS.remote, VETO_STEP_IDS);
  });

  it("Lesson 02 records exactly the ids the list holds", () => {
    assert.deepEqual(LESSON_STEPS.editing, SANDBOX_MISSIONS.map((mission) => mission.id));
  });

  it("the hub's fallback line states the total the lists add up to", () => {
    const total = Object.values(LESSON_STEPS).reduce((sum, steps) => sum + steps.length, 0);
    const hub = readFileSync(new URL("../../learn/index.html", import.meta.url), "utf8");
    assert.match(hub, new RegExp(`data-hub-overall>${total} hands-on browser missions across ${Object.keys(LESSON_STEPS).length} lessons`));
    for (const [lesson, steps] of Object.entries(LESSON_STEPS)) assert.match(hub, new RegExp(`data-lesson-progress="${lesson}">${steps.length} missions<`), lesson);
  });

  it("no lesson lists an id twice", () => {
    for (const [lesson, steps] of Object.entries(LESSON_STEPS)) assert.equal(new Set(steps).size, steps.length, lesson);
  });
});
