import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { missing, readPageLab } from "./support/page_copy.ts";
import {
  CAPTION_IDS,
  CHANGE_LINES,
  COMMAND_KEYS,
  EDIT_LINE,
  LINE_IDS,
  MOVES,
  OWN_LINE,
  SHARED_LINE,
  STEP_IDS,
  captionKeysText,
  createCoAuthorState,
  currentStep,
  doneSteps,
  fileLines,
  nextKeys,
  playNextMove,
  pressKey,
  type CaptionId,
  type CoAuthorState,
  type Command,
  type Move,
} from "../src/coauthor_state.ts";

const COMMANDS = Object.keys(COMMAND_KEYS) as Command[];

const press = (state: CoAuthorState, ...keys: string[]): CoAuthorState => keys.reduce((s, key) => pressKey(s, key).state, state);
const run = (state: CoAuthorState, ...commands: Command[]): CoAuthorState => commands.reduce((s, command) => press(s, ...COMMAND_KEYS[command]), state);

/** The visible file as "line:mark" pairs, so a table row can state the whole gutter. */
const file = (state: CoAuthorState): string =>
  fileLines(state)
    .filter((line) => line.visible)
    .map((line) => `${line.id}:${line.mark}`)
    .join(" ");

/** Everything except the caption, its keys and the keycast: what a key that does nothing must leave alone. */
const substance = ({ move, cursor, edited, changes }: CoAuthorState) => ({ move, cursor, edited, changes });

const TOP = "title:you gap_1:you intro:you gap_2:you heading:you save:you";
const FIRST = "interval:minga banner:minga";
const SECOND = "sync:minga retry:shared status:minga";

/** The command each move waits for, in order: the one path through the lab. */
const PATH: readonly Command[] = ["next_change", "edit", "undo", "reject", "next_change", "keep"];

/** The state at the start of each move. */
function atEachMove(): CoAuthorState[] {
  const states = [createCoAuthorState()];
  for (const command of PATH) states.push(run(states.at(-1)!, command));
  return states;
}

describe("same-file lab: what each move shows", () => {
  const table: readonly { move: Move; step: string | null; done: string; cursor: string; edited: boolean; file: string; caption: CaptionId; next: Command | null }[] = [
    { move: "find", step: "find", done: "", cursor: "title", edited: false, file: `${TOP} ${FIRST} slow:you ${SECOND}`, caption: "rest", next: "next_change" },
    { move: "edit", step: "edit_undo", done: "find", cursor: "interval", edited: false, file: `${TOP} ${FIRST} slow:you ${SECOND}`, caption: "found", next: "edit" },
    { move: "undo", step: "edit_undo", done: "find", cursor: "interval", edited: true, file: `${TOP} interval:shared banner:minga slow:you ${SECOND}`, caption: "edited", next: "undo" },
    { move: "reject", step: "reject", done: "find edit_undo", cursor: "interval", edited: false, file: `${TOP} ${FIRST} slow:you ${SECOND}`, caption: "undone", next: "reject" },
    { move: "find_other", step: "keep", done: "find edit_undo reject", cursor: "slow", edited: false, file: `${TOP} slow:you ${SECOND}`, caption: "rejected", next: "next_change" },
    { move: "keep", step: "keep", done: "find edit_undo reject", cursor: "sync", edited: false, file: `${TOP} slow:you ${SECOND}`, caption: "found_other", next: "keep" },
    { move: "finished", step: null, done: "find edit_undo reject keep", cursor: "sync", edited: false, file: `${TOP} slow:you sync:kept retry:kept status:kept`, caption: "kept", next: null },
  ];
  const states = atEachMove();

  it("the table covers every move", () => {
    assert.deepEqual(table.map((row) => row.move), MOVES);
    assert.equal(states.length, MOVES.length);
  });

  for (const [i, row] of table.entries()) {
    it(`${row.move}: step ${row.step}, caption ${row.caption}`, () => {
      const state = states[i]!;
      assert.equal(state.move, row.move);
      assert.equal(currentStep(state), row.step);
      assert.equal(doneSteps(state).join(" "), row.done);
      assert.equal(state.cursor, row.cursor);
      assert.equal(state.edited, row.edited);
      assert.equal(file(state), row.file);
      assert.equal(state.caption, row.caption);
      assert.deepEqual(nextKeys(state), row.next === null ? null : COMMAND_KEYS[row.next]);
    });
  }
});

describe("same-file lab: the first frame", () => {
  const lines = fileLines(createCoAuthorState());
  const marks = new Map(lines.map((line) => [line.id, line.mark]));

  it("shows the three kinds of line at once: yours, Minga's, and one you both wrote", () => {
    assert.ok(lines.every((line) => line.visible));
    assert.deepEqual([...new Set(lines.map((line) => line.mark))].sort(), ["minga", "shared", "you"]);
    assert.equal(marks.get(SHARED_LINE), "shared");
    assert.equal(marks.get(OWN_LINE), "you");
  });

  it("holds two separate changes by Minga, with a line of yours between them", () => {
    const order = (id: (typeof LINE_IDS)[number]): number => LINE_IDS.indexOf(id);
    assert.ok(order(CHANGE_LINES.first.at(-1)!) < order(OWN_LINE));
    assert.ok(order(OWN_LINE) < order(CHANGE_LINES.second[0]!));
    assert.ok(CHANGE_LINES.first.includes(EDIT_LINE));
    assert.ok(CHANGE_LINES.second.includes(SHARED_LINE));
    // The shared line is a middle line of its change, the one shape the mark drawings cover for it.
    assert.ok(CHANGE_LINES.second.indexOf(SHARED_LINE) > 0 && CHANGE_LINES.second.indexOf(SHARED_LINE) < CHANGE_LINES.second.length - 1);
  });
});

describe("same-file lab: what the four steps prove", () => {
  const [, found, edited, undone, rejected, , kept] = atEachMove() as [CoAuthorState, CoAuthorState, CoAuthorState, CoAuthorState, CoAuthorState, CoAuthorState, CoAuthorState];
  const mark = (state: CoAuthorState, id: string): string | undefined => fileLines(state).find((line) => line.id === id && line.visible)?.mark;

  it("the edit marks only the edited line as shared", () => {
    assert.equal(mark(found, EDIT_LINE), "minga");
    assert.equal(mark(edited, EDIT_LINE), "shared");
    assert.equal(file(edited).replace(`${EDIT_LINE}:shared`, `${EDIT_LINE}:minga`), file(found));
  });

  it("undo removes only the learner's edit: Minga's lines, the earlier shared line and the learner's own line stay", () => {
    assert.equal(undone.edited, false);
    assert.equal(file(undone), file(found));
    assert.deepEqual(undone.changes, { first: "unreviewed", second: "unreviewed" });
    assert.equal(mark(undone, SHARED_LINE), "shared");
  });

  it("reject removes that change's lines and leaves the learner's own line and the other change", () => {
    for (const id of CHANGE_LINES.first) assert.equal(mark(rejected, id), undefined, id);
    assert.equal(mark(rejected, OWN_LINE), "you");
    assert.deepEqual(rejected.changes, { first: "rejected", second: "unreviewed" });
    assert.equal(file(rejected), `${TOP} slow:you ${SECOND}`);
    assert.equal(rejected.cursor, OWN_LINE);
  });

  it("keep turns every mark of the other change into the kept mark and touches nothing else", () => {
    for (const id of CHANGE_LINES.second) assert.equal(mark(kept, id), "kept", id);
    assert.deepEqual(kept.changes, { first: "rejected", second: "kept" });
    assert.equal(file(kept), `${TOP} slow:you sync:kept retry:kept status:kept`);
  });
});

describe("same-file lab: steps complete only in order", () => {
  const states = atEachMove();

  for (const [i, state] of states.entries()) {
    const expected = PATH[i] ?? null;
    for (const command of COMMANDS) {
      if (command === expected) continue;
      it(`${state.move}: ${command} is bound, changes nothing in the file, and says so`, () => {
        const keys = COMMAND_KEYS[command];
        const before = press(state, ...keys.slice(0, -1));
        const result = pressKey(before, keys.at(-1)!);
        assert.equal(result.handled, true);
        assert.deepEqual(substance(result.state), substance(state));
        assert.equal(file(result.state), file(state));
        assert.equal(result.state.caption, state.move === "finished" ? "after_done" : `wrong_${state.move}`);
        assert.deepEqual(result.state.captionKeys, keys);
        assert.deepEqual(result.state.keycast.recent.at(-1), keys);
      });
    }
  }

  it("the same command twice does not skip a move", () => {
    const twice = run(createCoAuthorState(), "next_change", "next_change");
    assert.equal(twice.move, "edit");
    assert.equal(twice.caption, "wrong_edit");
  });
});

describe("same-file lab: a key the lab does not bind", () => {
  const states = atEachMove();

  for (const state of states) {
    it(`${state.move}: changes only the caption and the keycast, and is not kept from the page`, () => {
      for (const key of ["j", "w", "x", "ESC", "C-a"]) {
        const result = pressKey(state, key);
        assert.equal(result.handled, false, key);
        assert.deepEqual(substance(result.state), substance(state), key);
        assert.equal(result.state.caption, state.move === "finished" ? "after_done" : `unhandled_${state.move}`);
        assert.deepEqual(result.state.captionKeys, [key]);
        assert.deepEqual(result.state.keycast, { pending: [], recent: [...state.keycast.recent, [key]].slice(-3) });
      }
    });
  }

  it("names each key in turn under one caption id", () => {
    let state = createCoAuthorState();
    const named: string[] = [];
    for (const key of ["j", "w", "x"]) {
      state = press(state, key);
      assert.equal(state.caption, "unhandled_find");
      named.push(state.captionKeys.join(" "));
    }
    assert.deepEqual(named, ["j", "w", "x"]);
  });
});

describe("same-file lab: commands of more than one key", () => {
  it("waits on each prefix, shows it as pending, and keeps it from the page", () => {
    const table: readonly { keys: readonly string[]; pending: readonly string[] }[] = [
      { keys: ["]"], pending: ["]"] },
      { keys: ["SPC"], pending: ["SPC"] },
      { keys: ["SPC", "a"], pending: ["SPC", "a"] },
    ];
    for (const row of table) {
      const start = createCoAuthorState();
      const before = press(start, ...row.keys.slice(0, -1));
      const result = pressKey(before, row.keys.at(-1)!);
      assert.equal(result.handled, true, row.keys.join(" "));
      assert.equal(result.state.caption, "pending");
      assert.deepEqual(result.state.captionKeys, row.pending);
      assert.deepEqual(result.state.keycast.pending, row.pending);
      assert.deepEqual(substance(result.state), substance(start));
    }
  });

  it("a key that does not finish the command drops the prefix and reports the whole sequence", () => {
    const result = pressKey(press(createCoAuthorState(), "SPC", "a"), "x");
    assert.equal(result.handled, false);
    assert.equal(result.state.caption, "unhandled_find");
    assert.deepEqual(result.state.captionKeys, ["SPC", "a", "x"]);
    assert.deepEqual(result.state.keycast.pending, []);
    assert.equal(result.state.move, "find");
  });

  it("the caption names keys the way the site writes them", () => {
    const table: readonly [keys: readonly string[], text: string][] = [
      [["]", "h"], "]h"],
      [["]", "x"], "]x"],
      [["SPC", "a"], "SPC a"],
      [["SPC", "a", "d"], "SPC a d"],
      [["j"], "j"],
    ];
    for (const [keys, text] of table) assert.equal(captionKeysText(press(createCoAuthorState(), ...keys)), text);
    assert.equal(captionKeysText(createCoAuthorState()), "");
  });

  it("every command is reachable one key at a time, and only its last key runs it", () => {
    const states = atEachMove();
    for (const [i, command] of PATH.entries()) {
      const keys = COMMAND_KEYS[command];
      const before = press(states[i]!, ...keys.slice(0, -1));
      assert.equal(before.move, states[i]!.move, command);
      assert.equal(pressKey(before, keys.at(-1)!).state.move, MOVES[i + 1], command);
    }
  });
});

describe("same-file lab: the button that presses the keys", () => {
  it("walks the whole lab, one move per press, and stops at the end", () => {
    let state = createCoAuthorState();
    const moves: Move[] = [state.move];
    for (let i = 0; i < PATH.length; i += 1) {
      state = playNextMove(state);
      moves.push(state.move);
    }
    assert.deepEqual(moves, MOVES);
    assert.deepEqual(doneSteps(state), STEP_IDS);
    assert.equal(nextKeys(state), null);
    assert.deepEqual(substance(playNextMove(state)), substance(state));
  });

  it("drops a prefix the learner left waiting, so the move still runs", () => {
    const state = playNextMove(press(createCoAuthorState(), "SPC", "a"));
    assert.equal(state.move, "edit");
    assert.equal(state.caption, "found");
  });
});

describe("same-file lab: the page holds the words for every id the state emits", () => {
  const page = readPageLab("learn/agents.html", "data-coauthor-sim");

  /** Every caption the state can reach: each move, then every key or command from it. */
  function reachableCaptions(): CaptionId[] {
    const seen = new Set<CaptionId>();
    for (const state of atEachMove()) {
      seen.add(state.caption);
      for (const key of ["j", "]", "SPC"]) seen.add(pressKey(state, key).state.caption);
      for (const command of COMMANDS) seen.add(run(state, command).caption);
    }
    return [...seen];
  }

  it("the declared caption list is exactly what the state emits", () => {
    assert.deepEqual(reachableCaptions().sort(), [...CAPTION_IDS].sort());
  });

  it("every step is in the step list, in order, and every caption has its words there", () => {
    assert.deepEqual(page.steps, STEP_IDS);
    assert.deepEqual(missing(CAPTION_IDS, page.captions), []);
    assert.deepEqual(missing(page.captions, CAPTION_IDS), [], "the page has no caption the state never shows");
    assert.equal(new Set(page.captions).size, page.captions.length, "caption ids are unique");
  });

  it("every file line has its node in the stage, in order", () => {
    assert.deepEqual(page.attr("data-line"), LINE_IDS);
  });

  it("the first frame in the markup is the first frame of the state", () => {
    const authors = page.attr("data-author").slice(0, LINE_IDS.length);
    assert.deepEqual(authors, fileLines(createCoAuthorState()).map((line) => line.mark));
  });

  it("every caption that answers a key has a place to name it", () => {
    for (const id of CAPTION_IDS.filter((caption) => caption !== "rest")) {
      const caption = new RegExp(`data-lab-caption="${id}">(.*?)</p>`, "s").exec(page.html)?.[1] ?? "";
      assert.match(caption, /data-lab-key/, id);
    }
  });

  it("every line of a change names its mark in words for a screen reader, and the edit has both texts", () => {
    const changeLines = CHANGE_LINES.first.length + CHANGE_LINES.second.length;
    assert.deepEqual(page.attr("data-ca-mark"), Array.from({ length: changeLines }, () => ["minga", "shared", "kept"]).flat());
    assert.deepEqual(page.attr("data-ca-text"), ["base", "edit"]);
  });

  it("the page marks the lab the way the kit, the view and the stylesheet look for it", () => {
    assert.match(page.html, /<ol data-lab-steps>/);
    for (const hook of ["data-lab-stage", "data-lab-caption-line", "data-lab-stepper", "data-lab-keycast", "data-ca-play", "data-ca-reset"]) {
      assert.ok(page.html.includes(` ${hook}`), hook);
    }
  });

  it("the legend under the lab is three words", () => {
    const legend = /<ul class="ca-legend"[^>]*>(.*?)<\/ul>/s.exec(page.html)?.[1] ?? "";
    const words = Array.from(legend.matchAll(/<\/span>([^<]+)<\/li>/g), (m) => m[1]);
    assert.deepEqual(words, ["You", "Minga", "Both"]);
  });
});
