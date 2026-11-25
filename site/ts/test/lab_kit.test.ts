import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { esc } from "../src/lab/esc.ts";
import { createKeycast, keycastPush, keycastText } from "../src/lab/keycast.ts";
import { capturesKey, focusAfterControlClick, nextVisible, normalizeKey, stepPrefix } from "../src/lab/stage.ts";
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
    for (const key of ["Control", "Alt", "AltGraph", "OS", "Hyper", "Super", "Symbol", "CapsLock", "NumLock", "ScrollLock", "Fn"]) {
      assert.equal(normalizeKey({ key }), null, key);
    }
    for (const [event, name] of cases) assert.equal(normalizeKey(event), name, JSON.stringify(event));
  });

  it("names a character typed with AltGr as the character, not as a Control and Option chord", () => {
    const altGraph = (name: string): boolean => name === "AltGraph";
    assert.equal(normalizeKey({ key: "@", ctrlKey: true, altKey: true, getModifierState: altGraph }), "@");
    assert.equal(normalizeKey({ key: "€", altKey: true, getModifierState: altGraph }), "€");
    assert.equal(normalizeKey({ key: "Enter", ctrlKey: true, altKey: true, getModifierState: altGraph }), "C-M-RET");
    assert.equal(normalizeKey({ key: "q", ctrlKey: true, altKey: true, getModifierState: () => false }), "C-M-q");
    assert.equal(capturesKey({ key: "@", ctrlKey: true, altKey: true, getModifierState: altGraph }, false), true);
  });

  it("keeps a plain key in the focused stage", () => {
    assert.equal(capturesKey({ key: " " }, false), true);
    assert.equal(capturesKey({ key: "x" }, false), true);
    assert.equal(capturesKey({ key: "x" }, true), true);
    assert.equal(capturesKey({ key: "Escape" }, false), true);
  });

  it("never keeps Tab, Shift+Tab or a Command chord, even when the lab handled the key", () => {
    for (const handled of [false, true]) {
      assert.equal(capturesKey({ key: "Tab" }, handled), false, `Tab handled=${handled}`);
      assert.equal(capturesKey({ key: "Tab", shiftKey: true } as Parameters<typeof capturesKey>[0], handled), false, `Shift+Tab handled=${handled}`);
      assert.equal(capturesKey({ key: "j", metaKey: true }, handled), false, `Cmd+j handled=${handled}`);
      assert.equal(capturesKey({ key: "l", ctrlKey: true, metaKey: true }, handled), false, `Ctrl+Cmd+l handled=${handled}`);
    }
    assert.equal(normalizeKey({ key: "Tab" }), "TAB");
  });

  it("keeps a Control chord, an Option chord or a function key only when the lab handled it", () => {
    for (const key of ["j", "k", "t", "."]) {
      assert.equal(capturesKey({ key, ctrlKey: true }, true), true, `Ctrl+${key} handled`);
      assert.equal(capturesKey({ key, ctrlKey: true }, false), false, `Ctrl+${key} not handled`);
    }
    assert.equal(capturesKey({ key: "F5" }, false), false);
    assert.equal(capturesKey({ key: "F5" }, true), true);
    assert.equal(capturesKey({ key: "Enter", altKey: true }, false), false);
    assert.equal(capturesKey({ key: "Enter", altKey: true }, true), true);
  });
});

describe("lab kit: focus when a control goes away", () => {
  const controls = ["next", "replay", "back", "answer"];
  const visible = (...shown: string[]) => (id: string): boolean => shown.includes(id);

  it("moves to the next visible control after the lost one, wrapping round", () => {
    assert.equal(nextVisible(controls, "answer", visible("next", "back")), "next");
    assert.equal(nextVisible(controls, "next", visible("replay", "back")), "replay");
    assert.equal(nextVisible(controls, "replay", visible("next")), "next");
    assert.equal(nextVisible(controls, "back", visible("next", "answer")), "answer");
  });

  it("has no control to offer when none is visible, so focus goes to the stage", () => {
    assert.equal(nextVisible(controls, "answer", visible()), null);
    assert.equal(nextVisible(controls, "answer", visible("answer")), null);
    assert.equal(nextVisible([], "answer", visible("next")), null);
  });

  it("searches every control when the lost one is not in the order", () => {
    assert.equal(nextVisible(controls, "other", visible("back")), "back");
  });

  it("after a control click: a keyed lab takes a pointer click back to the stage, and a keyboard press keeps the control", () => {
    const table: readonly [keyed: boolean, pointer: boolean, gone: boolean, want: string][] = [
      [true, true, false, "stage"],
      [true, true, true, "stage"],
      [true, false, false, "stay"],
      [true, false, true, "rescue"],
      [false, true, false, "stay"],
      [false, true, true, "rescue"],
      [false, false, false, "stay"],
      [false, false, true, "rescue"],
    ];
    for (const [keyed, pointer, gone, want] of table) {
      assert.equal(focusAfterControlClick({ keyed, pointer, gone }), want, JSON.stringify({ keyed, pointer, gone }));
    }
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
    // Two sequences stay two entries; the renderer gives each its own element, so they never read as one.
    assert.deepEqual(cast.recent.map(keycastText), ["SPC ,", "x"]);
    assert.equal(cast.recent.length, 2);
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
