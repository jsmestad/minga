/*
 * State for the Lesson 02 lab: find a command through the leader menu.
 *
 * The lab is four steps in order: open the menu, look inside a group, open the file switcher and open a file, then close a menu without choosing.
 * Every key gets an answer. A key the lab binds changes the stage; any other key changes only the caption and the keycast.
 * Every value here is an id or a key name: the words (menu rows, file text, captions, step labels) live in site/learn/editing.html.
 */

import { createKeycast, KEYCAST_RECENT_LIMIT, type KeycastState } from "./lab/keycast.ts";
import { displayKeys, stepPrefix } from "./lab/stage.ts";

export type StepId = "menu" | "group" | "open_file" | "close";
/** The four steps. They are also the lesson's progress ids: LESSON_STEPS.editing in progress.ts lists the same ids, and a test holds the two together. */
export const STEP_IDS: readonly StepId[] = ["menu", "group", "open_file", "close"];

export const LEADER = "SPC";
/** The keys that close each surface. This is the one list of them, so a change of rule is a change of one line. */
export const CLOSE_KEYS: Readonly<Record<"menu" | "switcher", readonly string[]>> = {
  menu: ["ESC"],
  switcher: ["ESC"],
};
/** Goes up one level in the menu. At the top level it closes the menu. */
export const BACK_KEY = "DEL";
export const OPEN_KEY = "RET";
export const MOVE_DOWN_KEYS: readonly string[] = ["DOWN", "C-j"];
export const MOVE_UP_KEYS: readonly string[] = ["UP", "C-k"];

export type MenuId = "top" | "a" | "a_q" | "a_x" | "a_S" | "b" | "c" | "f" | "g" | "h" | "o" | "p" | "q" | "s" | "t" | "w";

export interface MenuSpec {
  /** Keys that open a group one level down. */
  readonly groups: readonly string[];
  /** Keys that run a command. */
  readonly leaves: readonly string[];
}

/** The menu tree, as keys only. The page holds one panel for each menu with one row for each key, and a test holds the two together. */
export const MENUS: Readonly<Record<MenuId, MenuSpec>> = {
  top: { groups: ["a", "b", "c", "f", "g", "h", "o", "p", "q", "s", "t", "w"], leaves: [LEADER, ","] },
  a: { groups: ["q", "x", "S"], leaves: ["a", "v", "r", "n", "i", "w", "s", "y", "d", "u", "?", "e", "W", "A", "p"] },
  a_q: { groups: [], leaves: ["q", "f"] },
  a_x: { groups: [], leaves: ["b", "f", "d", "l"] },
  a_S: { groups: [], leaves: ["h", "R", "m", "t", "l", "H", "k", "s"] },
  b: { groups: [], leaves: ["b", "D", "K"] },
  c: { groups: [], leaves: ["d", "D", "x", "v", "V"] },
  f: { groups: [], leaves: ["o", "s"] },
  g: { groups: [], leaves: ["g", "s", "b", "B"] },
  h: { groups: [], leaves: ["a", "c", "k"] },
  o: { groups: [], leaves: ["t", "T"] },
  p: { groups: [], leaves: ["h", "p"] },
  q: { groups: [], leaves: ["q", "n"] },
  s: { groups: [], leaves: ["p", "i", "j", "u", "q"] },
  t: { groups: [], leaves: ["l", "w", "i"] },
  w: { groups: [], leaves: ["v", "s", "d"] },
};

export const MENU_IDS = Object.keys(MENUS) as MenuId[];

/** The menu that a pending key sequence has open: the leader alone is the top menu, and each group key goes one level down. */
export function menuId(pending: readonly string[]): MenuId | null {
  if (pending.length === 0) return null;
  const id = pending.length === 1 ? "top" : pending.slice(1).join("_");
  return Object.hasOwn(MENUS, id) ? (id as MenuId) : null;
}

/** The keys that open a menu, the leader first. */
export function menuPath(id: MenuId): readonly string[] {
  return id === "top" ? [LEADER] : [LEADER, ...id.split("_")];
}

/** Every full command the menu holds, as key sequences. A group is the shared start of its rows, so the prefix tracker finds it without a list. */
export const SEQUENCES: readonly (readonly string[])[] = MENU_IDS.flatMap((id) => MENUS[id].leaves.map((key) => [...menuPath(id), key]));

/** The two commands that open the file switcher: the short one at the top of the menu and the one inside the buffers group. */
export const SWITCHER_KEYS: readonly (readonly string[])[] = [
  [LEADER, ","],
  [LEADER, "b", "b"],
];

/** The group the lab's own button looks inside. */
export const DEMO_GROUP = "b";

export type FileId = "readme" | "spec" | "sync" | "sync_test";
/** The files, in the order of the switcher's rows. */
export const FILE_IDS: readonly FileId[] = ["spec", "sync", "sync_test", "readme"];
export const START_FILE: FileId = "spec";
/** The row the highlight starts on when the switcher opens: the first file that is not the open one, so that opening it shows a change. */
export const SWITCHER_START = 1;

/** Keys a Vim user tries first in a file. Minga keeps their Vim meaning; the lab does not simulate them, and says so. */
const VIM_KEYS: ReadonlySet<string> = new Set([..."hjklwbeWBE0$^GgiIaAoOxXdDyYpPuUrRcCsSvV:/?nN.,;*#%~<>=zZmtTfF{}[]@JKHLMQ", "C-r", "C-d", "C-u", "C-f", "C-b", "C-o", "C-v", "C-w"]);

export type CaptionId =
  | "rest"
  | "menu_opened"
  | "menu_for_group"
  | "menu_for_switcher"
  | "menu_for_close"
  | "group_opened"
  | "group_for_close"
  | "back_for_switcher"
  | "back_more"
  | "back_for_close"
  | "wrong_group"
  | "switcher_opened"
  | "switcher_for_close"
  | "leaf"
  | "unlisted"
  | "closed_early"
  | "closed_done"
  | "moved"
  | "file_opened"
  | "file_opened_again"
  | "typing_switcher"
  | "other_switcher"
  | "vim_file"
  | "other_file"
  | "q_file"
  | "esc_file"
  | "after_done";

export const CAPTION_IDS: readonly CaptionId[] = [
  "rest",
  "menu_opened",
  "menu_for_group",
  "menu_for_switcher",
  "menu_for_close",
  "group_opened",
  "group_for_close",
  "back_for_switcher",
  "back_more",
  "back_for_close",
  "wrong_group",
  "switcher_opened",
  "switcher_for_close",
  "leaf",
  "unlisted",
  "closed_early",
  "closed_done",
  "moved",
  "file_opened",
  "file_opened_again",
  "typing_switcher",
  "other_switcher",
  "vim_file",
  "other_file",
  "q_file",
  "esc_file",
  "after_done",
];

/** The captions that answer a key press. Each names the keys, so each needs a key slot in the page. "rest" is the only caption shown before a key. */
export const ANSWERING_CAPTION_IDS: readonly CaptionId[] = CAPTION_IDS.filter((id) => id !== "rest");

export interface SandboxState {
  /** How many steps are done, in order. STEP_IDS.length means the lab is finished. */
  readonly done: number;
  readonly file: FileId;
  /** The highlighted row of the open switcher, or null when the switcher is closed. */
  readonly switcher: number | null;
  readonly caption: CaptionId;
  /** The keys the caption names: the key or the sequence just pressed. */
  readonly captionKeys: readonly string[];
  /** The pending keys are the open menu: the leader alone is the top menu, and nothing pending means no menu. */
  readonly keycast: KeycastState;
  /** How many keys the lab has taken. The caption line draws again for each one, so a repeated key is still answered. */
  readonly presses: number;
}

export function createSandboxState(): SandboxState {
  return { done: 0, file: START_FILE, switcher: null, caption: "rest", captionKeys: [], keycast: createKeycast(), presses: 0 };
}

export type Surface = "file" | "menu" | "switcher";

export function surface(state: SandboxState): Surface {
  if (state.switcher !== null) return "switcher";
  return state.keycast.pending.length > 0 ? "menu" : "file";
}

/** The open menu, or null when no menu is open. */
export function openMenu(state: SandboxState): MenuId | null {
  return state.switcher === null ? menuId(state.keycast.pending) : null;
}

/** The step the stepper shows, or null when the lab is finished. */
export function currentStep(state: SandboxState): StepId | null {
  return STEP_IDS[state.done] ?? null;
}

export function doneSteps(state: SandboxState): readonly StepId[] {
  return STEP_IDS.slice(0, state.done);
}

export function captionKeysText(state: SandboxState): string {
  return displayKeys(state.captionKeys);
}

function sameKeys(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((key, i) => key === b[i]);
}

export interface KeyResult {
  readonly state: SandboxState;
  /** True when the key is one the lab binds at this moment. The stage keeps a Control chord from the browser only then. */
  readonly handled: boolean;
}

interface Answer {
  readonly caption: CaptionId;
  /** The key or the whole sequence that the caption names and the keycast records. */
  readonly keys: readonly string[];
  /** The keys still pending after this press. Leaving it out closes the menu. */
  readonly pending?: readonly string[];
  /** Leaving it out keeps the switcher as it is. */
  readonly switcher?: number | null;
  readonly file?: FileId;
  /** The step this press completes. It counts only when it is the current step. */
  readonly completes?: StepId;
  readonly handled: boolean;
}

function settle(state: SandboxState, answer: Answer): KeyResult {
  const pending = answer.pending ?? [];
  // A sequence that is still waiting shows as pending only. A finished one, or one the lab answered without running, joins the recent list.
  const waiting = pending.length > 0 && sameKeys(pending, answer.keys);
  const recent = waiting ? state.keycast.recent : [...state.keycast.recent, answer.keys].slice(-KEYCAST_RECENT_LIMIT);
  const completes = answer.completes !== undefined && answer.completes === currentStep(state);
  return {
    state: {
      ...state,
      done: completes ? state.done + 1 : state.done,
      file: answer.file ?? state.file,
      switcher: answer.switcher === undefined ? state.switcher : answer.switcher,
      caption: answer.caption,
      captionKeys: answer.keys,
      keycast: { pending, recent },
    },
    handled: answer.handled,
  };
}

function inFile(state: SandboxState, key: string): Answer {
  if (key === LEADER) {
    const captions: Readonly<Record<StepId, CaptionId>> = { menu: "menu_opened", group: "menu_for_group", open_file: "menu_for_switcher", close: "menu_for_close" };
    return { caption: captions[currentStep(state)!], keys: [key], pending: [key], completes: "menu", handled: true };
  }
  if (key === "q") return { caption: "q_file", keys: [key], handled: false };
  if (key === "ESC") return { caption: "esc_file", keys: [key], handled: false };
  return { caption: VIM_KEYS.has(key) ? "vim_file" : "other_file", keys: [key], handled: false };
}

function closed(state: SandboxState, key: string): Answer {
  const last = currentStep(state) === "close";
  return { caption: last ? "closed_done" : "closed_early", keys: [key], switcher: null, completes: "close", handled: true };
}

function inMenu(state: SandboxState, key: string): Answer {
  const step = currentStep(state);
  const pending = state.keycast.pending;
  if (CLOSE_KEYS.menu.includes(key)) return closed(state, key);
  if (key === BACK_KEY) {
    if (pending.length === 1) return closed(state, key);
    const up = pending.slice(0, -1);
    const caption = step === "close" ? "back_for_close" : up.length === 1 ? "back_for_switcher" : "back_more";
    return { caption, keys: [key], pending: up, handled: true };
  }
  const next = stepPrefix(SEQUENCES, pending, key);
  if (next.status === "pending") {
    return { caption: step === "close" ? "group_for_close" : "group_opened", keys: next.keys, pending: next.pending, completes: "group", handled: true };
  }
  if (next.status === "unknown") return { caption: "unlisted", keys: next.keys, handled: false };
  if (SWITCHER_KEYS.some((keys) => sameKeys(keys, next.keys))) {
    // While the learner still has to look inside a group, the switcher waits: the menu stays open and the caption says why.
    if (step === "group") return { caption: "wrong_group", keys: next.keys, pending, handled: true };
    return { caption: step === "close" ? "switcher_for_close" : "switcher_opened", keys: next.keys, switcher: SWITCHER_START, handled: true };
  }
  return { caption: "leaf", keys: next.keys, handled: true };
}

function inSwitcher(state: SandboxState, selected: number, key: string): Answer {
  const count = FILE_IDS.length;
  if (CLOSE_KEYS.switcher.includes(key)) return closed(state, key);
  if (MOVE_DOWN_KEYS.includes(key)) return { caption: "moved", keys: [key], switcher: (selected + 1) % count, handled: true };
  if (MOVE_UP_KEYS.includes(key)) return { caption: "moved", keys: [key], switcher: (selected - 1 + count) % count, handled: true };
  if (key === OPEN_KEY) {
    const caption = currentStep(state) === "open_file" ? "file_opened" : "file_opened_again";
    return { caption, keys: [key], switcher: null, file: FILE_IDS[selected]!, completes: "open_file", handled: true };
  }
  // One character, or the space bar, is text for the prompt in Minga. Anything else is a chord or a named key.
  const typed = key === LEADER || Array.from(key).length === 1;
  return { caption: typed ? "typing_switcher" : "other_switcher", keys: [key], handled: false };
}

/** Feeds one key press, named the way the lab stage names keys, into the lab. */
export function pressKey(before: SandboxState, key: string): KeyResult {
  const state: SandboxState = { ...before, presses: before.presses + 1 };
  if (currentStep(state) === null) return settle(state, { caption: "after_done", keys: [key], handled: false });
  if (state.switcher !== null) return settle(state, inSwitcher(state, state.switcher, key));
  return settle(state, surface(state) === "menu" ? inMenu(state, key) : inFile(state, key));
}

/** A click on a switcher row: the row is highlighted and then opened, as the open key does. */
export function openRow(state: SandboxState, index: number): SandboxState {
  if (state.switcher === null || index < 0 || index >= FILE_IDS.length) return state;
  return pressKey({ ...state, switcher: index }, OPEN_KEY).state;
}

/** The key the current step waits for from where the lab is now, or null when the lab is finished. */
export function nextKey(state: SandboxState): string | null {
  const step = currentStep(state);
  if (step === null) return null;
  const where = surface(state);
  if (where === "file") return LEADER;
  if (step === "close") return CLOSE_KEYS[where][0]!;
  if (where === "switcher") return OPEN_KEY;
  if (step === "group") return DEMO_GROUP;
  return state.keycast.pending.length === 1 ? "," : BACK_KEY;
}

/** Presses the next key, as the lab's own button does for a reader with no keyboard. */
export function playNextKey(state: SandboxState): SandboxState {
  const key = nextKey(state);
  return key === null ? state : pressKey(state, key).state;
}
