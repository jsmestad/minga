import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { STEP_IDS } from "../src/coauthor_state.ts";
import { badgeState } from "../src/hub_view.ts";
import { completeMission, hubNext, LESSON_ORDER, LESSON_STEPS, type ProgressStore, readProgress, STORAGE_KEY, summarizeLesson } from "../src/progress.ts";
import { STEP_IDS as SANDBOX_STEP_IDS } from "../src/sandbox_state.ts";
import { STEP_IDS as VETO_STEP_IDS } from "../src/veto_state.ts";
import { missing, readPageLab } from "./support/page_copy.ts";

/** A Web Storage stand-in that holds whatever a test puts in it. */
function memoryStore(entries: Record<string, string> = {}): ProgressStore & { readonly entries: Record<string, string> } {
  return {
    entries,
    getItem: (key) => (Object.hasOwn(entries, key) ? entries[key]! : null),
    setItem: (key, value) => {
      entries[key] = value;
    },
  };
}

/** Every current id of every lesson: a reader who finished all four labs. */
const ALL_DONE = Object.fromEntries(LESSON_ORDER.map((lesson) => [lesson, [...LESSON_STEPS[lesson]]]));

describe("lesson progress: only a lesson's current ids count", () => {
  /** What a visitor who finished the old same-file simulator has in storage. */
  const OLD_AGENTS = ["per_author_undo", "lockout_guard", "subagent_peek", "review_change"];

  const table: readonly { name: string; stored: unknown; lesson: string; done: number; total: number }[] = [
    { name: "an empty store", stored: {}, lesson: "agents", done: 0, total: 4 },
    { name: "a partial store", stored: { editing: ["menu", "group"] }, lesson: "editing", done: 2, total: 4 },
    { name: "only ids from the old lab", stored: { agents: OLD_AGENTS }, lesson: "agents", done: 0, total: 4 },
    { name: "old and current ids mixed", stored: { agents: [...OLD_AGENTS, "find", "reject"] }, lesson: "agents", done: 2, total: 4 },
    { name: "every current id, with old ids beside them", stored: { agents: [...STEP_IDS, ...OLD_AGENTS] }, lesson: "agents", done: 4, total: 4 },
    { name: "only ids from the old key sandbox", stored: { editing: ["which_key", "pin_file", "act_menu", "parity", "dismiss"] }, lesson: "editing", done: 0, total: 4 },
    { name: "an id stored twice", stored: { agents: ["find", "find"] }, lesson: "agents", done: 1, total: 4 },
    { name: "another lesson's ids", stored: { editing: ["menu"], agents: ["menu"] }, lesson: "agents", done: 0, total: 4 },
    { name: "a lesson the site no longer has", stored: { "getting-started": ["configured"] }, lesson: "getting-started", done: 0, total: 0 },
    { name: "an unknown lesson id", stored: { advanced: ["a", "b"] }, lesson: "advanced", done: 0, total: 0 },
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

describe("lesson progress: storage", () => {
  it("reads nothing from an empty store", () => {
    assert.deepEqual(readProgress(memoryStore()), {});
  });

  it("reads nothing when storage is unavailable", () => {
    assert.deepEqual(readProgress(null), {});
  });

  it("reads nothing from a store that is not JSON", () => {
    assert.deepEqual(readProgress(memoryStore({ [STORAGE_KEY]: "{not json" })), {});
  });

  it("ignores a store written under the old key, even when it holds every current id", () => {
    const store = memoryStore({ "minga-learn-progress-v1": JSON.stringify(ALL_DONE) });
    const stored = readProgress(store);
    for (const lesson of LESSON_ORDER) assert.deepEqual(summarizeLesson(stored, lesson), { done: 0, total: LESSON_STEPS[lesson].length }, lesson);
    assert.deepEqual(hubNext(stored), { kind: "start" });
  });

  it("the key is not the old key", () => {
    assert.notEqual(STORAGE_KEY, "minga-learn-progress-v1");
  });

  it("records a step under the current key and leaves the old key alone", () => {
    const old = JSON.stringify({ editing: ["which_key"] });
    const store = memoryStore({ "minga-learn-progress-v1": old });
    completeMission("editing", "menu", store);
    completeMission("editing", "menu", store);
    completeMission("remote", "blocked", store);
    assert.deepEqual(JSON.parse(store.entries[STORAGE_KEY]!), { editing: ["menu"], remote: ["blocked"] });
    assert.equal(store.entries["minga-learn-progress-v1"], old);
    assert.deepEqual(summarizeLesson(readProgress(store), "editing"), { done: 1, total: 4 });
  });

  it("does nothing when storage is unavailable", () => {
    assert.doesNotThrow(() => completeMission("editing", "menu", null));
  });
});

describe("the hub's next step", () => {
  const table: readonly { name: string; stored: unknown; next: ReturnType<typeof hubNext> }[] = [
    { name: "an empty store starts at Getting Started", stored: {}, next: { kind: "start" } },
    { name: "a store that is not an object starts at Getting Started", stored: null, next: { kind: "start" } },
    { name: "only old or unknown ids start at Getting Started", stored: { editing: ["which_key"], advanced: ["a"] }, next: { kind: "start" } },
    { name: "a partly done first lesson continues that lesson", stored: { editing: ["menu"] }, next: { kind: "continue", lesson: "editing" } },
    { name: "a finished first lesson continues with the second", stored: { editing: [...SANDBOX_STEP_IDS] }, next: { kind: "continue", lesson: "agents" } },
    { name: "a partly done third lesson continues that lesson when the first two are finished", stored: { editing: [...SANDBOX_STEP_IDS], agents: [...STEP_IDS], elixir: ["translated"] }, next: { kind: "continue", lesson: "elixir" } },
    { name: "a later lesson with progress still continues with the first unfinished one", stored: { remote: ["blocked"] }, next: { kind: "continue", lesson: "editing" } },
    { name: "every step of every lesson is done", stored: ALL_DONE, next: { kind: "done" } },
  ];

  for (const row of table) {
    it(row.name, () => {
      assert.deepEqual(hubNext(row.stored), row.next);
    });
  }
});

describe("the hub's progress badge", () => {
  it("names a state for no steps, some steps and every step", () => {
    assert.equal(badgeState(0, 4), "none");
    assert.equal(badgeState(1, 4), "some");
    assert.equal(badgeState(3, 4), "some");
    assert.equal(badgeState(4, 4), "all");
  });
});

describe("lesson progress: the list, the labs and the hub page agree", () => {
  const hub = readPageLab("learn/index.html", "data-learn-hub");

  it("the same-file lab records exactly the ids the list holds", () => {
    assert.deepEqual(LESSON_STEPS.agents, STEP_IDS);
  });

  it("the hook lab records exactly the ids the list holds", () => {
    assert.deepEqual(LESSON_STEPS.remote, VETO_STEP_IDS);
  });

  it("the find-a-command lab records exactly the ids the list holds", () => {
    assert.deepEqual(LESSON_STEPS.editing, SANDBOX_STEP_IDS);
  });

  it("no lesson lists an id twice", () => {
    for (const [lesson, steps] of Object.entries(LESSON_STEPS)) assert.equal(new Set(steps).size, steps.length, lesson);
  });

  it("the reading order holds every lesson once", () => {
    assert.deepEqual([...LESSON_ORDER].sort(), Object.keys(LESSON_STEPS).sort());
  });

  it("each lesson card states its own step count, in every badge state", () => {
    for (const [lesson, steps] of Object.entries(LESSON_STEPS)) {
      const n = steps.length;
      assert.match(hub.html, new RegExp(`data-lesson-progress="${lesson}"><span data-progress-state="none">${n} steps</span><span data-progress-state="some" hidden><span data-progress-done>0</span> of ${n} steps done</span><span data-progress-state="all" hidden>`), lesson);
    }
  });

  it("the page has words for every next step the hub can pick, and shows the first visit without a script", () => {
    const ids = ["start", ...LESSON_ORDER, "done"];
    assert.deepEqual(missing(ids, hub.attr("data-hub-next")), []);
    assert.deepEqual(missing(hub.attr("data-hub-next"), ids), []);
    assert.match(hub.html, /<div data-hub-next="start">/);
    for (const id of ids.slice(1)) assert.match(hub.html, new RegExp(`<div data-hub-next="${id}" hidden>`), id);
  });

  it("each Continue link opens its own lesson", () => {
    for (const lesson of LESSON_ORDER) assert.match(hub.html, new RegExp(`data-hub-next="${lesson}" hidden>\\s*<a class="btn btn-primary" href="/learn/${lesson}">`), lesson);
  });

  it("the page makes no claim about a total number of steps or missions", () => {
    assert.doesNotMatch(hub.html, /missions?\b/i);
    assert.doesNotMatch(hub.html, /data-hub-overall/);
  });
});
