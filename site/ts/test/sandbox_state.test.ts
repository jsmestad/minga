import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { missing, readPageLab } from "./support/page_copy.ts";
import {
  ANSWERING_CAPTION_IDS,
  BACK_KEY,
  CAPTION_IDS,
  CLOSE_KEYS,
  FILE_IDS,
  LEADER,
  MENU_IDS,
  MENUS,
  MOVE_DOWN_KEYS,
  MOVE_UP_KEYS,
  OPEN_KEY,
  SEQUENCES,
  START_FILE,
  STEP_IDS,
  SWITCHER_KEYS,
  SWITCHER_START,
  captionKeysText,
  createSandboxState,
  currentStep,
  doneSteps,
  menuPath,
  nextKey,
  openMenu,
  openRow,
  playNextKey,
  pressKey,
  surface,
  type CaptionId,
  type MenuId,
  type SandboxState,
  type StepId,
  type Surface,
} from "../src/sandbox_state.ts";
import { keycastText } from "../src/lab/keycast.ts";

const press = (state: SandboxState, ...keys: string[]): SandboxState => keys.reduce((s, key) => pressKey(s, key).state, state);

/** Everything a key that only gets an answer must leave alone: the step, the file, the open menu and the switcher. */
const substance = (state: SandboxState) => ({ done: state.done, file: state.file, switcher: state.switcher, pending: state.keycast.pending });

/** The keys of the one path through the lab, as the lab's own button presses them. */
const PATH: readonly string[] = [LEADER, "b", BACK_KEY, ",", OPEN_KEY, LEADER, "ESC"];

/** Named places in the lab: each step with each surface it can show. */
const AT = {
  rest: [] as string[],
  step2_file: [LEADER, "ESC"],
  step2_top: [LEADER],
  step3_group: [LEADER, "b"],
  step3_subgroup: [LEADER, "a", "S"],
  step3_top: [LEADER, "b", BACK_KEY],
  step3_file: [LEADER, "b", "ESC"],
  step3_switcher: [LEADER, "b", BACK_KEY, ","],
  step4_file: [LEADER, "b", BACK_KEY, ",", OPEN_KEY],
  step4_top: [LEADER, "b", BACK_KEY, ",", OPEN_KEY, LEADER],
  step4_group: [LEADER, "b", BACK_KEY, ",", OPEN_KEY, LEADER, "g"],
  step4_subgroup: [LEADER, "b", BACK_KEY, ",", OPEN_KEY, LEADER, "a", "q"],
  step4_switcher: [LEADER, "b", BACK_KEY, ",", OPEN_KEY, LEADER, ","],
  finished: [...PATH],
} as const;
type Place = keyof typeof AT;
const PLACES = Object.keys(AT) as Place[];
const at = (place: Place): SandboxState => press(createSandboxState(), ...AT[place]);

describe("find-a-command lab: where each place is", () => {
  const table: readonly { place: Place; step: StepId | null; surface: Surface; menu: MenuId | null; next: string | null }[] = [
    { place: "rest", step: "menu", surface: "file", menu: null, next: "SPC" },
    { place: "step2_file", step: "group", surface: "file", menu: null, next: "SPC" },
    { place: "step2_top", step: "group", surface: "menu", menu: "top", next: "b" },
    { place: "step3_group", step: "open_file", surface: "menu", menu: "b", next: "DEL" },
    { place: "step3_subgroup", step: "open_file", surface: "menu", menu: "a_S", next: "DEL" },
    { place: "step3_top", step: "open_file", surface: "menu", menu: "top", next: "," },
    { place: "step3_file", step: "open_file", surface: "file", menu: null, next: "SPC" },
    { place: "step3_switcher", step: "open_file", surface: "switcher", menu: null, next: "RET" },
    { place: "step4_file", step: "close", surface: "file", menu: null, next: "SPC" },
    { place: "step4_top", step: "close", surface: "menu", menu: "top", next: "ESC" },
    { place: "step4_group", step: "close", surface: "menu", menu: "g", next: "ESC" },
    { place: "step4_subgroup", step: "close", surface: "menu", menu: "a_q", next: "ESC" },
    { place: "step4_switcher", step: "close", surface: "switcher", menu: null, next: "ESC" },
    { place: "finished", step: null, surface: "file", menu: null, next: null },
  ];

  it("the table covers every place", () => {
    assert.deepEqual(table.map((row) => row.place), PLACES);
  });

  for (const row of table) {
    it(`${row.place}: step ${row.step}, ${row.surface}, next key ${row.next}`, () => {
      const state = at(row.place);
      assert.equal(currentStep(state), row.step);
      assert.equal(surface(state), row.surface);
      assert.equal(openMenu(state), row.menu);
      assert.equal(nextKey(state), row.next);
      assert.deepEqual(doneSteps(state), row.step === null ? STEP_IDS : STEP_IDS.slice(0, STEP_IDS.indexOf(row.step)));
    });
  }
});

interface Row {
  readonly place: Place;
  readonly key: string;
  readonly caption: CaptionId;
  /** The keys the caption names, as shown. */
  readonly names: string;
  readonly handled: boolean;
  /** Where the lab is after the key. Left out, the key changes only the caption and the keycast. */
  readonly then?: { readonly step?: StepId | null; readonly surface?: Surface; readonly menu?: MenuId | null; readonly file?: string; readonly row?: number };
}

describe("find-a-command lab: every key gets an answer", () => {
  const table: readonly Row[] = [
    // Nothing open: the file has focus.
    { place: "rest", key: "SPC", caption: "menu_opened", names: "SPC", handled: true, then: { step: "group", surface: "menu", menu: "top" } },
    { place: "rest", key: "j", caption: "vim_file", names: "j", handled: false },
    { place: "rest", key: "k", caption: "vim_file", names: "k", handled: false },
    { place: "rest", key: "w", caption: "vim_file", names: "w", handled: false },
    { place: "rest", key: "i", caption: "vim_file", names: "i", handled: false },
    { place: "rest", key: ":", caption: "vim_file", names: ":", handled: false },
    { place: "rest", key: "x", caption: "vim_file", names: "x", handled: false },
    { place: "rest", key: "K", caption: "vim_file", names: "K", handled: false },
    { place: "rest", key: "é", caption: "other_file", names: "é", handled: false },
    { place: "rest", key: "C-r", caption: "vim_file", names: "⌃R", handled: false },
    { place: "rest", key: "C-a", caption: "other_file", names: "⌃A", handled: false },
    { place: "rest", key: "F5", caption: "other_file", names: "F5", handled: false },
    { place: "rest", key: "RET", caption: "other_file", names: "↩", handled: false },
    { place: "rest", key: "DEL", caption: "other_file", names: "⌫", handled: false },
    { place: "rest", key: "q", caption: "q_file", names: "q", handled: false },
    { place: "rest", key: "ESC", caption: "esc_file", names: "esc", handled: false },
    { place: "step2_file", key: "SPC", caption: "menu_for_group", names: "SPC", handled: true, then: { surface: "menu", menu: "top" } },
    { place: "step2_file", key: "j", caption: "vim_file", names: "j", handled: false },
    { place: "step2_file", key: "q", caption: "q_file", names: "q", handled: false },
    { place: "step3_file", key: "SPC", caption: "menu_for_switcher", names: "SPC", handled: true, then: { surface: "menu", menu: "top" } },
    { place: "step3_file", key: "ESC", caption: "esc_file", names: "esc", handled: false },
    { place: "step4_file", key: "SPC", caption: "menu_for_close", names: "SPC", handled: true, then: { surface: "menu", menu: "top" } },
    { place: "step4_file", key: "q", caption: "q_file", names: "q", handled: false },
    { place: "step4_file", key: "ESC", caption: "esc_file", names: "esc", handled: false },
    { place: "step4_file", key: "w", caption: "vim_file", names: "w", handled: false },

    // The top menu, while the learner still has to look inside a group.
    { place: "step2_top", key: "b", caption: "group_opened", names: "SPC b", handled: true, then: { step: "open_file", menu: "b" } },
    { place: "step2_top", key: "a", caption: "group_opened", names: "SPC a", handled: true, then: { step: "open_file", menu: "a" } },
    { place: "step2_top", key: "q", caption: "group_opened", names: "SPC q", handled: true, then: { step: "open_file", menu: "q" } },
    { place: "step2_top", key: "w", caption: "group_opened", names: "SPC w", handled: true, then: { step: "open_file", menu: "w" } },
    { place: "step2_top", key: ",", caption: "wrong_group", names: "SPC ,", handled: true },
    { place: "step2_top", key: "SPC", caption: "leaf", names: "SPC SPC", handled: true, then: { surface: "file", menu: null } },
    { place: "step2_top", key: "z", caption: "unlisted", names: "SPC z", handled: false, then: { surface: "file", menu: null } },
    { place: "step2_top", key: "i", caption: "unlisted", names: "SPC i", handled: false, then: { surface: "file", menu: null } },
    { place: "step2_top", key: "RET", caption: "unlisted", names: "SPC ↩", handled: false, then: { surface: "file", menu: null } },
    { place: "step2_top", key: "ESC", caption: "closed_early", names: "esc", handled: true, then: { step: "group", surface: "file", menu: null } },
    { place: "step2_top", key: "DEL", caption: "closed_early", names: "⌫", handled: true, then: { step: "group", surface: "file", menu: null } },

    // A group, on the way to the switcher.
    { place: "step3_group", key: "DEL", caption: "back_for_switcher", names: "⌫", handled: true, then: { menu: "top" } },
    { place: "step3_group", key: "b", caption: "switcher_opened", names: "SPC b b", handled: true, then: { surface: "switcher", menu: null, row: SWITCHER_START } },
    { place: "step3_group", key: "D", caption: "leaf", names: "SPC b D", handled: true, then: { surface: "file", menu: null } },
    { place: "step3_group", key: "j", caption: "unlisted", names: "SPC b j", handled: false, then: { surface: "file", menu: null } },
    { place: "step3_group", key: "q", caption: "unlisted", names: "SPC b q", handled: false, then: { surface: "file", menu: null } },
    { place: "step3_group", key: "ESC", caption: "closed_early", names: "esc", handled: true, then: { step: "open_file", surface: "file", menu: null } },
    { place: "step3_subgroup", key: "DEL", caption: "back_more", names: "⌫", handled: true, then: { menu: "a" } },
    { place: "step3_subgroup", key: "m", caption: "leaf", names: "SPC a S m", handled: true, then: { surface: "file", menu: null } },
    { place: "step3_subgroup", key: "ESC", caption: "closed_early", names: "esc", handled: true, then: { surface: "file", menu: null } },

    // The top menu, on the way to the switcher.
    { place: "step3_top", key: ",", caption: "switcher_opened", names: "SPC ,", handled: true, then: { surface: "switcher", menu: null, row: SWITCHER_START } },
    { place: "step3_top", key: "a", caption: "group_opened", names: "SPC a", handled: true, then: { menu: "a" } },
    { place: "step3_top", key: "SPC", caption: "leaf", names: "SPC SPC", handled: true, then: { surface: "file", menu: null } },
    { place: "step3_top", key: "DEL", caption: "closed_early", names: "⌫", handled: true, then: { surface: "file", menu: null } },

    // The switcher, with a file still to open.
    { place: "step3_switcher", key: "DOWN", caption: "moved", names: "↓", handled: true, then: { row: 2 } },
    { place: "step3_switcher", key: "C-j", caption: "moved", names: "⌃J", handled: true, then: { row: 2 } },
    { place: "step3_switcher", key: "UP", caption: "moved", names: "↑", handled: true, then: { row: 0 } },
    { place: "step3_switcher", key: "C-k", caption: "moved", names: "⌃K", handled: true, then: { row: 0 } },
    { place: "step3_switcher", key: "RET", caption: "file_opened", names: "↩", handled: true, then: { step: "close", surface: "file", file: "sync" } },
    { place: "step3_switcher", key: "ESC", caption: "closed_early", names: "esc", handled: true, then: { step: "open_file", surface: "file", file: START_FILE } },
    { place: "step3_switcher", key: "q", caption: "typing_switcher", names: "q", handled: false },
    { place: "step3_switcher", key: "j", caption: "typing_switcher", names: "j", handled: false },
    { place: "step3_switcher", key: "SPC", caption: "typing_switcher", names: "SPC", handled: false },
    { place: "step3_switcher", key: "C-t", caption: "other_switcher", names: "⌃T", handled: false },
    { place: "step3_switcher", key: "DEL", caption: "other_switcher", names: "⌫", handled: false },

    // The last step: whatever is open, the close key finishes the lab.
    { place: "step4_top", key: "ESC", caption: "closed_done", names: "esc", handled: true, then: { step: null, surface: "file", menu: null } },
    { place: "step4_top", key: "DEL", caption: "closed_done", names: "⌫", handled: true, then: { step: null, surface: "file", menu: null } },
    { place: "step4_top", key: "q", caption: "group_for_close", names: "SPC q", handled: true, then: { step: "close", menu: "q" } },
    { place: "step4_top", key: ",", caption: "switcher_for_close", names: "SPC ,", handled: true, then: { step: "close", surface: "switcher", menu: null, row: SWITCHER_START } },
    { place: "step4_top", key: "z", caption: "unlisted", names: "SPC z", handled: false, then: { step: "close", surface: "file", menu: null } },
    { place: "step4_group", key: "ESC", caption: "closed_done", names: "esc", handled: true, then: { step: null, surface: "file", menu: null } },
    { place: "step4_group", key: "DEL", caption: "back_for_close", names: "⌫", handled: true, then: { step: "close", menu: "top" } },
    { place: "step4_group", key: "g", caption: "leaf", names: "SPC g g", handled: true, then: { step: "close", surface: "file", menu: null } },
    { place: "step4_subgroup", key: "DEL", caption: "back_for_close", names: "⌫", handled: true, then: { step: "close", menu: "a" } },
    { place: "step4_subgroup", key: "ESC", caption: "closed_done", names: "esc", handled: true, then: { step: null, surface: "file", menu: null } },
    { place: "step4_switcher", key: "ESC", caption: "closed_done", names: "esc", handled: true, then: { step: null, surface: "file", file: "sync" } },
    { place: "step4_switcher", key: "q", caption: "typing_switcher", names: "q", handled: false },
    { place: "step4_switcher", key: "DOWN", caption: "moved", names: "↓", handled: true, then: { row: 2 } },
    { place: "step4_switcher", key: "RET", caption: "file_opened_again", names: "↩", handled: true, then: { step: "close", surface: "file", file: "sync" } },

    // Finished: every key says so and changes nothing.
    { place: "finished", key: "SPC", caption: "after_done", names: "SPC", handled: false },
    { place: "finished", key: "ESC", caption: "after_done", names: "esc", handled: false },
    { place: "finished", key: "q", caption: "after_done", names: "q", handled: false },
    { place: "finished", key: "j", caption: "after_done", names: "j", handled: false },
  ];

  for (const row of table) {
    it(`${row.place}: ${row.key} shows ${row.caption}`, () => {
      const before = at(row.place);
      const { state, handled } = pressKey(before, row.key);
      assert.equal(state.caption, row.caption);
      assert.equal(captionKeysText(state), row.names);
      assert.equal(handled, row.handled);
      assert.equal(state.presses, before.presses + 1);
      if (!row.then) {
        assert.deepEqual(substance(state), substance(before));
        return;
      }
      if (row.then.step !== undefined) assert.equal(currentStep(state), row.then.step, "step");
      if (row.then.surface !== undefined) assert.equal(surface(state), row.then.surface, "surface");
      if (row.then.menu !== undefined) assert.equal(openMenu(state), row.then.menu, "menu");
      if (row.then.file !== undefined) assert.equal(state.file, row.then.file, "file");
      if (row.then.row !== undefined) assert.equal(state.switcher, row.then.row, "row");
    });
  }

  it("the table reaches every place", () => {
    assert.deepEqual(missing(PLACES, table.map((row) => row.place)), []);
  });

  it("every key answers at every place: the caption names that key, and the press is counted", () => {
    const keys = ["j", "k", "w", "i", ":", "x", "q", "a", "b", ",", "z", "0", "SPC", "ESC", "RET", "DEL", "UP", "DOWN", "C-j", "C-k", "C-t", "M-x", "F1"];
    for (const place of PLACES) {
      for (const key of keys) {
        const before = at(place);
        const { state } = pressKey(before, key);
        assert.notEqual(state.caption, "rest", `${place} ${key}`);
        assert.equal(state.presses, before.presses + 1, `${place} ${key}`);
        assert.equal(state.captionKeys.at(-1), key, `${place} ${key}`);
      }
    }
  });

  it("the same unbound key twice is two answers: the caption stays and the press count moves", () => {
    for (const place of PLACES) {
      // The first press may close a menu. From then on the lab is at rest in one surface, and the key repeats.
      const once = press(at(place), "F1", "F1");
      const twice = press(once, "F1");
      assert.equal(twice.caption, once.caption, place);
      assert.equal(captionKeysText(twice), captionKeysText(once), place);
      assert.equal(twice.presses, once.presses + 1, place);
      assert.deepEqual(substance(twice), substance(once), place);
    }
  });

  it("q closes nothing anywhere: in a file it is the macro key, in the top menu it is a group, in the switcher it is text", () => {
    assert.deepEqual(CLOSE_KEYS, { menu: ["ESC"], switcher: ["ESC"] });
    for (const place of PLACES) {
      const before = at(place);
      const after = press(before, "q");
      if (surface(before) !== "menu") assert.deepEqual(substance(after), substance(before), place);
      if (currentStep(before) === "close") assert.equal(currentStep(after), "close", place);
    }
    assert.equal(openMenu(press(at("step4_top"), "q")), "q");
  });
});

describe("find-a-command lab: the menu", () => {
  it("every group key opens its group from the top menu, and the pending keys are the open menu", () => {
    for (const key of MENUS.top.groups) {
      const state = press(at("step2_top"), key);
      assert.equal(openMenu(state), key);
      assert.deepEqual(state.keycast.pending, [LEADER, key]);
      assert.deepEqual(doneSteps(state), ["menu", "group"]);
    }
  });

  it("every row of every menu is bound where it is shown", () => {
    for (const id of MENU_IDS) {
      const open = press(at("step3_file"), ...menuPath(id));
      assert.equal(openMenu(open), id, id);
      for (const key of MENUS[id].groups) {
        const { state, handled } = pressKey(open, key);
        assert.ok(handled, `${id} ${key}`);
        assert.deepEqual(state.keycast.pending, [...menuPath(id), key], `${id} ${key}`);
        assert.notEqual(openMenu(state), null, `${id} ${key} has a panel`);
      }
      for (const key of MENUS[id].leaves) {
        const { state, handled } = pressKey(open, key);
        assert.ok(handled, `${id} ${key}`);
        assert.ok(state.caption === "leaf" || state.caption === "switcher_opened", `${id} ${key}`);
        assert.equal(openMenu(state), null, `${id} ${key}`);
      }
    }
  });

  it("no menu uses one key for two rows, and the back and close keys are never rows", () => {
    for (const id of MENU_IDS) {
      const keys = [...MENUS[id].groups, ...MENUS[id].leaves];
      assert.equal(new Set(keys).size, keys.length, id);
      for (const key of [BACK_KEY, ...CLOSE_KEYS.menu]) assert.ok(!keys.includes(key), `${id} ${key}`);
    }
  });

  it("both switcher commands are rows of the menu", () => {
    for (const keys of SWITCHER_KEYS) assert.ok(SEQUENCES.some((sequence) => sequence.join(" ") === keys.join(" ")), keys.join(" "));
  });

  it("the keycast shows the open menu as pending and a finished command as one entry", () => {
    let state = at("step3_top");
    assert.deepEqual(state.keycast.pending, [LEADER]);
    state = press(state, ",");
    assert.deepEqual(state.keycast.pending, []);
    assert.equal(keycastText(state.keycast.recent.at(-1)!), "SPC ,");
    state = press(at("step3_group"), "D");
    assert.equal(keycastText(state.keycast.recent.at(-1)!), "SPC b D");
    assert.ok(state.keycast.recent.length <= 3);
  });

  it("Escape with a prefix pending drops the prefix and records the key", () => {
    for (const place of ["step2_top", "step3_group", "step3_subgroup"] as const) {
      const state = press(at(place), "ESC");
      assert.deepEqual(state.keycast.pending, [], place);
      assert.deepEqual(state.keycast.recent.at(-1), ["ESC"], place);
      assert.equal(surface(state), "file", place);
    }
  });

  it("a switcher key pressed too early leaves the menu open and still shows in the keycast", () => {
    const state = press(at("step2_top"), ",");
    assert.deepEqual(state.keycast.pending, [LEADER]);
    assert.deepEqual(state.keycast.recent.at(-1), [LEADER, ","]);
    assert.equal(openMenu(state), "top");
  });
});

describe("find-a-command lab: the switcher", () => {
  it("the highlight starts on a file that is not the open one", () => {
    const state = at("step3_switcher");
    assert.equal(state.switcher, SWITCHER_START);
    assert.notEqual(FILE_IDS[SWITCHER_START], START_FILE);
  });

  it("the highlight moves one row at a time and wraps at both ends, so a move key always moves it", () => {
    let state = at("step3_switcher");
    const seen: number[] = [];
    for (let i = 0; i < FILE_IDS.length; i += 1) {
      state = press(state, MOVE_DOWN_KEYS[0]!);
      seen.push(state.switcher!);
    }
    assert.deepEqual(seen, [2, 3, 0, 1]);
    assert.equal(press(press(at("step3_switcher"), MOVE_UP_KEYS[0]!), MOVE_UP_KEYS[0]!).switcher, FILE_IDS.length - 1);
  });

  it("the open key opens the highlighted file, whichever it is", () => {
    for (let moves = 0; moves < FILE_IDS.length; moves += 1) {
      const down = Array.from({ length: moves }, () => "DOWN");
      const state = press(at("step3_switcher"), ...down, OPEN_KEY);
      assert.equal(state.file, FILE_IDS[(SWITCHER_START + moves) % FILE_IDS.length]);
      assert.equal(state.switcher, null);
      assert.equal(currentStep(state), "close");
    }
  });

  it("a click on a row opens that row, as the open key does", () => {
    FILE_IDS.forEach((id, index) => {
      const state = openRow(at("step3_switcher"), index);
      assert.equal(state.file, id);
      assert.equal(state.caption, "file_opened");
      assert.equal(currentStep(state), "close");
    });
    assert.deepEqual(openRow(at("step3_top"), 0), at("step3_top"), "no switcher, no row to open");
    assert.deepEqual(openRow(at("step3_switcher"), 9), at("step3_switcher"), "no such row");
  });
});

describe("find-a-command lab: the button path equals the key path", () => {
  it("pressing the next key each time is the path, key for key, and ends finished", () => {
    let byButton = createSandboxState();
    let byKeys = createSandboxState();
    const pressed: string[] = [];
    while (nextKey(byButton) !== null) {
      const key = nextKey(byButton)!;
      pressed.push(key);
      byButton = playNextKey(byButton);
      byKeys = press(byKeys, key);
      assert.deepEqual(byButton, byKeys);
      assert.ok(pressed.length <= PATH.length, "the button always moves forward");
    }
    assert.deepEqual(pressed, PATH);
    assert.deepEqual(byButton, press(createSandboxState(), ...PATH));
    assert.deepEqual(doneSteps(byButton), STEP_IDS);
    assert.equal(byButton.caption, "closed_done");
    assert.deepEqual(playNextKey(byButton), byButton);
  });

  it("from any place the button reaches the end in a few presses", () => {
    for (const place of PLACES) {
      let state = at(place);
      for (let i = 0; i < 8 && nextKey(state) !== null; i += 1) state = playNextKey(state);
      assert.equal(currentStep(state), null, place);
    }
  });

  it("each step completes once, in order, and only on its own key", () => {
    const done = PATH.map((_, i) => doneSteps(press(createSandboxState(), ...PATH.slice(0, i + 1))).length);
    assert.deepEqual(done, [1, 2, 2, 2, 3, 3, 4]);
  });
});

describe("find-a-command lab: the page holds the words for every id the state emits", () => {
  const page = readPageLab("learn/editing.html", "data-minga-sandbox");

  /** Every caption the state can reach: each place, then every kind of key from it. */
  function reachableCaptions(): CaptionId[] {
    const seen = new Set<CaptionId>();
    const keys = ["j", "q", "K", "a", "b", "D", "S", "z", ",", "SPC", "ESC", "RET", "DEL", "DOWN", "C-t"];
    for (const place of PLACES) {
      const state = at(place);
      seen.add(state.caption);
      for (const key of keys) seen.add(pressKey(state, key).state.caption);
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

  it("every caption that answers a key has a place to name it", () => {
    for (const id of ANSWERING_CAPTION_IDS) {
      const caption = new RegExp(`data-lab-caption="${id}">(.*?)</p>`, "s").exec(page.html)?.[1] ?? "";
      assert.match(caption, /data-lab-key/, id);
    }
  });

  /** The rows of one menu panel in the page, as [key, is a group] pairs. */
  function panelRows(id: MenuId): [string, boolean][] {
    const panel = new RegExp(`<div class="lk-menu" data-menu="${id}" hidden>(.*?)</ul>`, "s").exec(page.html)?.[1] ?? "";
    return Array.from(panel.matchAll(/<li( class="lk-group")? data-key="([^"]+)"><kbd>([^<]+)<\/kbd> ([^<]+)<\/li>/g), (m) => {
      assert.equal(m[2], m[3], `${id}: the row shows the key it presses`);
      assert.equal(m[4]!.endsWith(" ›"), m[1] !== undefined, `${id} ${m[2]}: a group, and only a group, ends in the chevron`);
      return [m[2]!, m[1] !== undefined];
    });
  }

  it("the page has one panel for each menu, and each panel shows exactly the keys the state binds there", () => {
    assert.deepEqual(page.attr("data-menu"), MENU_IDS);
    for (const id of MENU_IDS) {
      const rows = panelRows(id);
      assert.deepEqual(rows.filter(([, group]) => group).map(([key]) => key).sort(), [...MENUS[id].groups].sort(), `${id} groups`);
      assert.deepEqual(rows.filter(([, group]) => !group).map(([key]) => key).sort(), [...MENUS[id].leaves].sort(), `${id} rows`);
    }
  });

  it("every file has its text, its title, its status-line name and its switcher row, and only the open file shows at first", () => {
    const parts = Array.from(page.html.matchAll(/data-file="([^"]+)"( hidden)?/g), (m) => ({ id: m[1]!, hidden: m[2] !== undefined }));
    for (const id of FILE_IDS) assert.equal(parts.filter((part) => part.id === id).length, 4, id);
    assert.deepEqual(missing(parts.map((part) => part.id), FILE_IDS), []);
    for (const part of parts) assert.equal(part.hidden, part.id !== START_FILE, part.id);
    assert.deepEqual(page.attr("data-switch-row"), FILE_IDS);
  });

  it("the switcher's header names only keys the switcher binds", () => {
    const hints = /<span class="lk-sw-hints">(.*?)<\/span><\/p>/s.exec(page.html)?.[1] ?? "";
    const shown = Array.from(hints.matchAll(/<kbd>([^<]+)<\/kbd>/g), (m) => m[1]);
    assert.deepEqual(shown, ["↓", "↑", "⌃J", "⌃K", "↩", "esc"]);
    const bound = [...MOVE_DOWN_KEYS, ...MOVE_UP_KEYS, OPEN_KEY, ...CLOSE_KEYS.switcher];
    assert.equal(bound.length, shown.length);
  });

  it("the page marks the lab the way the kit, the view and the stylesheet look for it", () => {
    assert.match(page.html, /<ol data-lab-steps>/);
    for (const hook of ["data-lab-stage", "data-lab-caption-line", "data-lab-stepper", "data-lab-keycast", "data-lk-play", "data-lk-reset", "data-lk-menus", "data-lk-switcher"]) {
      assert.ok(page.html.includes(` ${hook}`), hook);
    }
    assert.ok(page.html.includes('data-key="SPC">NORMAL'), "the mode pill opens the menu");
  });

  it("the lab has two controls outside the editor frame", () => {
    assert.equal((page.html.match(/<button\b/g) ?? []).length, 2);
  });
});
