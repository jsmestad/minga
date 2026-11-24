import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { canGoNext, createTimeline, timelineTimerMs } from "../src/lab/timeline.ts";
import {
  BEATS,
  boardCards,
  captionId,
  columnCount,
  createSpecBoardState,
  frameOf,
  isEdited,
  linkedLine,
  promptId,
  reachedBeats,
  reduceSpecBoard,
  SPEC_BOARD_FRAMES,
  specLines,
  stageInView,
  statusWord,
  YOUR_TURN_TIMEOUT_MS,
  type Beat,
  type SpecBoardEvent,
  type SpecBoardState,
} from "../src/spec_board_state.ts";

const send = (state: SpecBoardState, ...types: SpecBoardEvent["type"][]): SpecBoardState =>
  types.reduce((s, type) => reduceSpecBoard(s, { type }), state);

/** The first stepped stop of each beat, plus the edited "your turn" frame. */
function steppedFrames(): SpecBoardState[] {
  let s = send(createSpecBoardState("stepped"), "start");
  const out = [s];
  while (canGoNext(s)) {
    s = send(s, "next");
    out.push(s);
  }
  return out;
}

const authors = (state: SpecBoardState): string =>
  specLines(state)
    .filter((line) => line.visible)
    .map((line) => `${line.id}:${line.author}`)
    .join(" ");

describe("spec to board demo: what each beat shows", () => {
  const YOURS = "title:you gap_1:you intro:you gap_2:you heading:you save:you";
  const table: readonly { beat: Beat; edited: boolean; spec: string; caption: string; status: string | null; prompt: string | null; board: string | null }[] = [
    { beat: "rest", edited: false, spec: `${YOURS} sync:you`, caption: "rest", status: null, prompt: null, board: null },
    { beat: "ask_edit", edited: false, spec: `${YOURS} sync:you`, caption: "ask_edit", status: null, prompt: "prompt_edit", board: null },
    { beat: "minga_edits", edited: false, spec: `${YOURS} sync:minga retry:minga status:minga`, caption: "minga_edits", status: "working", prompt: "prompt_edit", board: null },
    { beat: "your_turn", edited: false, spec: `${YOURS} sync:minga retry:minga status:minga`, caption: "your_turn", status: null, prompt: null, board: null },
    { beat: "your_turn", edited: true, spec: `${YOURS} sync:minga retry:shared status:minga`, caption: "your_turn_done", status: null, prompt: null, board: null },
    { beat: "ask_board", edited: true, spec: `${YOURS} sync:minga retry:shared status:minga`, caption: "ask_board", status: null, prompt: "prompt_board", board: null },
    { beat: "board_builds", edited: true, spec: `${YOURS} sync:minga retry:shared status:minga`, caption: "board_builds", status: "working", prompt: "prompt_board", board: "done done working waiting" },
    { beat: "done", edited: true, spec: `${YOURS} sync:minga retry:shared status:minga`, caption: "done", status: "done", prompt: "prompt_board", board: "done done done done" },
  ];

  it("stepped mode visits every beat in order, and each stop derives the spec authors, caption, status, prompt and board", () => {
    const frames = steppedFrames();
    assert.equal(frames.length, table.length);
    frames.forEach((state, i) => {
      const want = table[i]!;
      const label = `stop ${i} (${want.beat})`;
      assert.equal(frameOf(state).beat, want.beat, label);
      assert.equal(isEdited(state), want.edited, label);
      assert.equal(authors(state), want.spec, label);
      assert.equal(captionId(state), want.caption, label);
      assert.equal(statusWord(state), want.status, label);
      assert.equal(promptId(state), want.prompt, label);
      assert.equal(boardCards(state)?.map((card) => card.column).join(" ") ?? null, want.board, label);
    });
    assert.deepEqual([...new Set(frames.map((s) => frameOf(s).beat))], BEATS);
  });

  it("Back walks the same stops in reverse to the opening frame", () => {
    const frames = steppedFrames();
    let s = frames.at(-1)!;
    const seen: number[] = [];
    for (let i = 0; i < frames.length - 1; i += 1) {
      s = send(s, "back");
      seen.push(s.index);
    }
    assert.deepEqual(seen, frames.slice(0, -1).map((f) => f.index).reverse());
    assert.equal(send(s, "back").index, 0);
  });

  it("the right pane is empty until the board builds, and the board has one card per requirement line", () => {
    for (const [index, frame] of SPEC_BOARD_FRAMES.entries()) {
      const state: SpecBoardState = { mode: "timed", index, phase: "holding" };
      assert.equal(boardCards(state) === null, frame.beat !== "board_builds" && frame.beat !== "done", `frame ${index}`);
    }
    const done = steppedFrames().at(-1)!;
    assert.deepEqual(boardCards(done)?.map((card) => card.id), ["save", "sync", "retry", "status"]);
    const lineIds = specLines(done).map((line) => line.id as string);
    for (const card of boardCards(done)!) assert.ok(lineIds.includes(card.id), `${card.id} is a spec line`);
  });

  it("the edited line is shared on every frame from the edit on, so its card carries the edit", () => {
    const from = SPEC_BOARD_FRAMES.findIndex((frame) => frame.turnTaken);
    SPEC_BOARD_FRAMES.forEach((_, index) => {
      const state: SpecBoardState = { mode: "timed", index, phase: "holding" };
      const retry = specLines(state).find((line) => line.id === "retry")!;
      assert.equal(retry.author === "shared", index >= from, `frame ${index}`);
      assert.equal(isEdited(state), index >= from, `frame ${index}`);
    });
  });

  it("cards only move forward, one column at a time, and the working card names its spec line", () => {
    const order = ["waiting", "working", "done"];
    let previous: readonly string[] | null = null;
    for (const [index] of SPEC_BOARD_FRAMES.entries()) {
      const state: SpecBoardState = { mode: "timed", index, phase: "holding" };
      const cards = boardCards(state);
      if (!cards) continue;
      const columns = cards.map((card) => card.column);
      if (previous) {
        columns.forEach((column, i) => {
          const step = order.indexOf(column) - order.indexOf(previous![i]!);
          assert.ok(step === 0 || step === 1, `frame ${index} card ${i}`);
        });
      }
      previous = columns;
      assert.equal(columnCount(state, "waiting") + columnCount(state, "working") + columnCount(state, "done"), 4);
      assert.equal(linkedLine(state), cards.find((card) => card.column === "working")?.id ?? null);
    }
    assert.deepEqual(previous, ["done", "done", "done", "done"]);
  });

  it("counts the beats reached for the stepper", () => {
    const frames = steppedFrames();
    assert.deepEqual(reachedBeats(frames[0]!), ["rest"]);
    assert.deepEqual(reachedBeats(frames.at(-1)!), BEATS);
  });
});

describe("spec to board demo: the timed run", () => {
  it("waits about four seconds at the visitor's turn, then makes the edit itself", () => {
    let s = send(createSpecBoardState("timed"), "start", "elapsed", "elapsed", "elapsed");
    assert.equal(frameOf(s).beat, "your_turn");
    assert.equal(s.phase, "prompt");
    assert.equal(isEdited(s), false);
    assert.equal(timelineTimerMs(SPEC_BOARD_FRAMES, s), YOUR_TURN_TIMEOUT_MS);
    assert.equal(YOUR_TURN_TIMEOUT_MS, 4000);
    s = send(s, "elapsed");
    assert.equal(frameOf(s).beat, "your_turn");
    assert.equal(isEdited(s), true);
    assert.equal(captionId(s), "your_turn_done");
  });

  it("a tap at the visitor's turn makes the same edit at once", () => {
    const waiting = send(createSpecBoardState("timed"), "start", "elapsed", "elapsed", "elapsed");
    const tapped = send(waiting, "answer");
    assert.deepEqual(tapped, send(waiting, "elapsed"));
    assert.equal(isEdited(tapped), true);
  });

  it("plays every frame once, ends on the final frame, and Replay returns to rest", () => {
    const clockRuns: (() => void)[] = [];
    const beats: Beat[] = [];
    const timeline = createTimeline(SPEC_BOARD_FRAMES, {
      mode: "timed",
      clock: { set: (run) => clockRuns.push(run), clear: () => {} },
      onChange: (state) => beats.push(frameOf(state).beat),
    });
    timeline.send({ type: "start" });
    while (timeline.state().phase !== "ended") clockRuns.shift()!();
    assert.equal(beats.length, SPEC_BOARD_FRAMES.length);
    assert.deepEqual([...new Set(beats)], BEATS);
    assert.equal(statusWord(timeline.state()), "done");
    assert.equal(timelineTimerMs(SPEC_BOARD_FRAMES, timeline.state()), null);

    timeline.send({ type: "start" });
    assert.equal(timeline.state().phase, "ended");
    timeline.send({ type: "replay" });
    assert.equal(frameOf(timeline.state()).beat, "rest");
    assert.equal(isEdited(timeline.state()), false);
    assert.equal(boardCards(timeline.state()), null);
  });
});

describe("spec to board demo: when it starts", () => {
  it("starts when half of the stage is visible, or when a tall stage fills half of the viewport", () => {
    assert.equal(stageInView(0.5, 300, 900), true);
    assert.equal(stageInView(0.49, 300, 900), false);
    assert.equal(stageInView(0.3, 420, 800), true);
    assert.equal(stageInView(0, 0, 0), false);
  });
});
