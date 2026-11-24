import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { esc } from "../src/lab/esc.ts";
import { createKeycast, keycastPush, keycastText } from "../src/lab/keycast.ts";
import { capturesKey, normalizeKey, stepPrefix } from "../src/lab/stage.ts";
import { stepperModel } from "../src/lab/stepper.ts";
import {
  canGoBack,
  canGoNext,
  createTimeline,
  createTimelineState,
  reduceTimeline,
  timelineTimerMs,
  type TimelineFrame,
  type TimelineState,
} from "../src/lab/timeline.ts";

describe("lab kit: esc", () => {
  it("escapes the five characters that can break out of text or an attribute", () => {
    assert.equal(esc(`<a href="x" title='y'>&</a>`), "&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;&lt;/a&gt;");
  });
});

describe("lab kit: key names", () => {
  it("names keys the way the site writes them", () => {
    const cases: readonly [Parameters<typeof normalizeKey>[0], string | null][] = [
      [{ key: " " }, "SPC"],
      [{ key: "Escape" }, "ESC"],
      [{ key: "Enter" }, "RET"],
      [{ key: "Tab" }, "TAB"],
      [{ key: "ArrowDown" }, "DOWN"],
      [{ key: "a" }, "a"],
      [{ key: "A" }, "A"],
      [{ key: "," }, ","],
      [{ key: "j", ctrlKey: true }, "C-j"],
      [{ key: "Enter", altKey: true }, "M-RET"],
      [{ key: "s", metaKey: true }, "D-s"],
      [{ key: "Shift" }, null],
      [{ key: "Meta", metaKey: true }, null],
    ];
    for (const [event, name] of cases) assert.equal(normalizeKey(event), name, JSON.stringify(event));
  });

  it("keeps a plain key in the focused stage and leaves Tab and browser shortcuts to the browser", () => {
    assert.equal(capturesKey({ key: " " }, false), true);
    assert.equal(capturesKey({ key: "x" }, false), true);
    assert.equal(capturesKey({ key: "Tab" }, false), false);
    assert.equal(capturesKey({ key: "F5" }, false), false);
    assert.equal(capturesKey({ key: "r", metaKey: true }, false), false);
    assert.equal(capturesKey({ key: "j", ctrlKey: true }, true), true);
  });
});

describe("lab kit: pending prefix", () => {
  const sequences = [["SPC", "a", "y"], ["SPC", ","], ["g", "."], ["K"]];

  it("waits on a prefix, matches a full sequence, and clears the pending keys on a match", () => {
    let step = stepPrefix(sequences, [], "SPC");
    assert.deepEqual(step, { status: "pending", pending: ["SPC"], keys: ["SPC"] });
    step = stepPrefix(sequences, step.pending, "a");
    assert.equal(step.status, "pending");
    step = stepPrefix(sequences, step.pending, "y");
    assert.deepEqual(step, { status: "matched", pending: [], keys: ["SPC", "a", "y"] });
    assert.equal(stepPrefix(sequences, [], "K").status, "matched");
  });

  it("reports a key that fits no sequence, with the keys tried, and drops the prefix", () => {
    assert.deepEqual(stepPrefix(sequences, ["SPC"], "z"), { status: "unknown", pending: [], keys: ["SPC", "z"] });
    assert.deepEqual(stepPrefix(sequences, [], "q"), { status: "unknown", pending: [], keys: ["q"] });
  });

  it("prefers a full sequence over a longer one that starts the same way", () => {
    assert.equal(stepPrefix([["g"], ["g", "g"]], [], "g").status, "matched");
  });
});

describe("lab kit: keycast", () => {
  it("shows pending keys, then moves a finished or unknown sequence to the recent list", () => {
    const sequences = [["SPC", ","]];
    let cast = createKeycast();
    let step = stepPrefix(sequences, cast.pending, "SPC");
    cast = keycastPush(cast, step);
    assert.deepEqual(cast, { pending: ["SPC"], recent: [] });
    step = stepPrefix(sequences, cast.pending, ",");
    cast = keycastPush(cast, step);
    assert.deepEqual(cast, { pending: [], recent: [["SPC", ","]] });
    cast = keycastPush(cast, stepPrefix(sequences, cast.pending, "x"));
    assert.deepEqual(cast.recent.map(keycastText), ["SPC ,", "x"]);
  });

  it("keeps only the newest sequences", () => {
    let cast = createKeycast();
    for (const key of ["a", "b", "c", "d"]) cast = keycastPush(cast, stepPrefix([], [], key), 3);
    assert.deepEqual(cast.recent, [["b"], ["c"], ["d"]]);
  });
});

describe("lab kit: stepper", () => {
  const steps = [
    { id: "open", instruction: "Open the file", captionIds: ["open"] },
    { id: "edit", instruction: "Change one line", captionIds: ["edit"] },
    { id: "keep", instruction: "Keep the change", captionIds: ["keep"] },
  ];

  it("gives the current step's position and label and counts each done step once", () => {
    assert.deepEqual(stepperModel(steps, "edit", ["open", "open", "nope"]), { position: 2, total: 3, doneCount: 1, label: "Change one line" });
  });

  it("has no position or label for an id that is not a step", () => {
    assert.deepEqual(stepperModel(steps, "missing"), { position: 0, total: 3, doneCount: 0, label: "" });
  });
});

describe("lab kit: timeline", () => {
  const frames: readonly TimelineFrame[] = [
    { holdMs: 100 },
    { holdMs: 200, stop: true },
    { holdMs: 4000, prompt: true, stop: true },
    { holdMs: 300 },
    { holdMs: 0 },
  ];
  const run = (state: TimelineState, ...events: Parameters<typeof reduceTimeline>[2]["type"][]): TimelineState =>
    events.reduce((s, type) => reduceTimeline(frames, s, { type }), state);

  it("timed mode holds each frame, waits at the prompt, and ends on the last frame", () => {
    let s = run(createTimelineState("timed"), "start");
    assert.deepEqual([s.index, s.phase, timelineTimerMs(frames, s)], [0, "holding", 100]);
    s = run(s, "elapsed", "elapsed");
    assert.deepEqual([s.index, s.phase, timelineTimerMs(frames, s)], [2, "prompt", 4000]);
    s = run(s, "answer");
    assert.deepEqual([s.index, s.phase], [3, "holding"]);
    s = run(s, "elapsed");
    assert.deepEqual([s.index, s.phase, timelineTimerMs(frames, s)], [4, "ended", null]);
    assert.equal(run(s, "elapsed"), s);
  });

  it("answers the prompt for the visitor when its time runs out", () => {
    const s = run(createTimelineState("timed"), "start", "elapsed", "elapsed", "elapsed");
    assert.deepEqual([s.index, s.phase], [3, "holding"]);
  });

  it("ignores an answer when no prompt is open, and Next and Back in timed mode", () => {
    const s = run(createTimelineState("timed"), "start");
    assert.equal(run(s, "answer"), s);
    assert.equal(run(s, "next"), s);
    assert.equal(run(s, "back"), s);
  });

  it("replay returns to the first frame from any frame", () => {
    const ended = run(createTimelineState("timed"), "start", "elapsed", "elapsed", "answer", "elapsed");
    assert.deepEqual(run(ended, "replay"), { mode: "timed", index: 0, phase: "holding" });
  });

  it("stepped mode never asks for a timer and moves between stops with Next and Back", () => {
    let s = run(createTimelineState("stepped"), "start");
    const seen = [s.index];
    assert.equal(canGoBack(s), false);
    while (canGoNext(s)) {
      assert.equal(timelineTimerMs(frames, s), null);
      assert.equal(run(s, "elapsed"), s);
      s = run(s, "next");
      seen.push(s.index);
    }
    assert.deepEqual(seen, [0, 1, 2, 4]);
    assert.equal(s.phase, "ended");
    assert.equal(timelineTimerMs(frames, s), null);
    assert.deepEqual([run(s, "back").index, run(s, "back", "back").index, run(s, "back", "back", "back").index], [2, 1, 0]);
  });

  it("the runner starts one timer per frame, clears it when the visitor answers, and starts none in stepped mode", () => {
    const pending = new Map<number, { run: () => void; ms: number }>();
    let nextHandle = 1;
    const clock = {
      set: (fn: () => void, ms: number) => {
        pending.set(nextHandle, { run: fn, ms });
        return nextHandle++;
      },
      clear: (handle: unknown) => void pending.delete(handle as number),
    };
    const fire = (): void => {
      const [handle, timer] = [...pending.entries()][0]!;
      pending.delete(handle);
      timer.run();
    };
    const seen: number[] = [];
    const timeline = createTimeline(frames, { mode: "timed", clock, onChange: (s) => seen.push(s.index) });

    assert.equal(pending.size, 0);
    timeline.send({ type: "start" });
    assert.deepEqual([...pending.values()].map((t) => t.ms), [100]);
    fire();
    fire();
    assert.deepEqual([...pending.values()].map((t) => t.ms), [4000]);
    timeline.send({ type: "answer" });
    assert.deepEqual([...pending.values()].map((t) => t.ms), [300]);
    fire();
    assert.equal(pending.size, 0);
    assert.deepEqual(seen, [0, 1, 2, 3, 4]);
    timeline.send({ type: "replay" });
    assert.deepEqual([...pending.values()].map((t) => t.ms), [100]);

    const stepped = createTimeline(frames, { mode: "stepped", clock: { set: () => assert.fail("stepped mode started a timer"), clear: () => {} }, onChange: () => {} });
    stepped.send({ type: "start" });
    stepped.send({ type: "next" });
    stepped.send({ type: "next" });
    stepped.send({ type: "replay" });
    assert.equal(stepped.state().index, 0);
  });
});
