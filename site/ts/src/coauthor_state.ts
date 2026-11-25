/*
 * State for the Lesson 03 lab: you and Minga work in the same file.
 *
 * The lab is one sequence of moves. Each move waits for one command; the right command changes the file and goes to the next move.
 * Any other key changes only the caption and the keycast. Every value here is an id: the words (file text, captions, step labels) live in site/learn/agents.html.
 */

import { createKeycast, keycastPush, type KeycastState } from "./lab/keycast.ts";
import { stepPrefix } from "./lab/stage.ts";

export type StepId = "find" | "edit_undo" | "reject" | "keep";
export const STEP_IDS: readonly StepId[] = ["find", "edit_undo", "reject", "keep"];

/** A step holds one or two moves. "finished" comes after the last step. */
export type Move = "find" | "edit" | "undo" | "reject" | "find_other" | "keep" | "finished";
export type WaitingMove = Exclude<Move, "finished">;
export const MOVES: readonly Move[] = ["find", "edit", "undo", "reject", "find_other", "keep", "finished"];

export type Command = "next_change" | "edit" | "undo" | "reject" | "keep";

/** The keys of each command, one array item per key press. */
export const COMMAND_KEYS: Readonly<Record<Command, readonly string[]>> = {
  next_change: ["]", "h"],
  edit: ["i"],
  undo: ["u"],
  reject: ["SPC", "a", "d"],
  keep: ["SPC", "a", "y"],
};

const COMMANDS = Object.keys(COMMAND_KEYS) as Command[];
const SEQUENCES: readonly (readonly string[])[] = COMMANDS.map((command) => COMMAND_KEYS[command]);

interface MoveSpec {
  readonly step: StepId;
  readonly expects: Command;
}

const MOVE_SPECS: Readonly<Record<WaitingMove, MoveSpec>> = {
  find: { step: "find", expects: "next_change" },
  edit: { step: "edit_undo", expects: "edit" },
  undo: { step: "edit_undo", expects: "undo" },
  reject: { step: "reject", expects: "reject" },
  find_other: { step: "keep", expects: "next_change" },
  keep: { step: "keep", expects: "keep" },
};

export type LineId = "title" | "gap_1" | "intro" | "gap_2" | "heading" | "save" | "interval" | "banner" | "slow" | "sync" | "retry" | "status";
export const LINE_IDS: readonly LineId[] = ["title", "gap_1", "intro", "gap_2", "heading", "save", "interval", "banner", "slow", "sync", "retry", "status"];

export type ChangeId = "first" | "second";
export type ChangeStatus = "unreviewed" | "kept" | "rejected";

/** Minga's two changes. The first is two added lines; the second holds the line the learner edited before the lab starts. */
export const CHANGE_LINES: Readonly<Record<ChangeId, readonly LineId[]>> = {
  first: ["interval", "banner"],
  second: ["sync", "retry", "status"],
};

/** The line of the first change that the edit move changes. */
export const EDIT_LINE: LineId = "interval";
/** The line of the second change that carries the learner's edit from the first frame. */
export const SHARED_LINE: LineId = "retry";
/** The learner's own line between the two changes. It must outlive the reject. */
export const OWN_LINE: LineId = "slow";

/** The gutter mark of a line: the learner's, Minga's, both, or one of Minga's lines after it is kept. */
export type Mark = "you" | "minga" | "shared" | "kept";

export type CaptionId =
  | "rest"
  | "found"
  | "edited"
  | "undone"
  | "rejected"
  | "found_other"
  | "kept"
  | "pending"
  | `unhandled_${WaitingMove}`
  | `wrong_${WaitingMove}`
  | "after_done";

const WAITING_MOVES = MOVES.filter((move): move is WaitingMove => move !== "finished");

export const CAPTION_IDS: readonly CaptionId[] = [
  "rest",
  "found",
  "edited",
  "undone",
  "rejected",
  "found_other",
  "kept",
  "pending",
  ...WAITING_MOVES.map((move): CaptionId => `unhandled_${move}`),
  ...WAITING_MOVES.map((move): CaptionId => `wrong_${move}`),
  "after_done",
];

export interface CoAuthorState {
  readonly move: Move;
  readonly cursor: LineId;
  /** The learner's edit inside Minga's first change is in the file. */
  readonly edited: boolean;
  readonly changes: Readonly<Record<ChangeId, ChangeStatus>>;
  readonly caption: CaptionId;
  /** The keys the caption names: the sequence just pressed, or the prefix still waiting. */
  readonly captionKeys: readonly string[];
  readonly keycast: KeycastState;
}

export function createCoAuthorState(): CoAuthorState {
  return {
    move: "find",
    cursor: "title",
    edited: false,
    changes: { first: "unreviewed", second: "unreviewed" },
    caption: "rest",
    captionKeys: [],
    keycast: createKeycast(),
  };
}

function sameKeys(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((key, i) => key === b[i]);
}

function nextMove(move: Move): Move {
  return MOVES[Math.min(MOVES.indexOf(move) + 1, MOVES.length - 1)]!;
}

/** The file after the command that a move waits for. */
function applyMove(state: CoAuthorState, move: WaitingMove): Pick<CoAuthorState, "cursor" | "edited" | "changes" | "caption"> {
  const { cursor, edited, changes } = state;
  switch (move) {
    case "find":
      return { cursor: CHANGE_LINES.first[0]!, edited, changes, caption: "found" };
    case "edit":
      return { cursor, edited: true, changes, caption: "edited" };
    case "undo":
      return { cursor, edited: false, changes, caption: "undone" };
    case "reject":
      return { cursor: OWN_LINE, edited, changes: { ...changes, first: "rejected" }, caption: "rejected" };
    case "find_other":
      return { cursor: CHANGE_LINES.second[0]!, edited, changes, caption: "found_other" };
    case "keep":
      return { cursor, edited, changes: { ...changes, second: "kept" }, caption: "kept" };
  }
}

function runCommand(state: CoAuthorState, command: Command, keys: readonly string[]): CoAuthorState {
  if (state.move === "finished") return { ...state, caption: "after_done", captionKeys: keys };
  if (MOVE_SPECS[state.move].expects !== command) return { ...state, caption: `wrong_${state.move}`, captionKeys: keys };
  return { ...state, ...applyMove(state, state.move), move: nextMove(state.move), captionKeys: keys };
}

export interface KeyResult {
  readonly state: CoAuthorState;
  /** True when the key is one the lab binds: a whole command or the start of one. The stage keeps only those keys from the page. */
  readonly handled: boolean;
}

/** Feeds one key press, named the way the lab stage names keys, into the lab. */
export function pressKey(state: CoAuthorState, key: string): KeyResult {
  const step = stepPrefix(SEQUENCES, state.keycast.pending, key);
  const keycast = keycastPush(state.keycast, step);
  if (step.status === "pending") {
    return { state: { ...state, keycast, caption: "pending", captionKeys: step.keys }, handled: true };
  }
  if (step.status === "unknown") {
    const caption: CaptionId = state.move === "finished" ? "after_done" : `unhandled_${state.move}`;
    return { state: { ...state, keycast, caption, captionKeys: step.keys }, handled: false };
  }
  const command = COMMANDS.find((name) => sameKeys(COMMAND_KEYS[name], step.keys))!;
  return { state: runCommand({ ...state, keycast }, command, step.keys), handled: true };
}

/** The keys the current move waits for, or null when the lab is finished. */
export function nextKeys(state: CoAuthorState): readonly string[] | null {
  return state.move === "finished" ? null : COMMAND_KEYS[MOVE_SPECS[state.move].expects];
}

/** Presses the keys the current move waits for, as the lab's own button does for a reader with no keyboard. A prefix still waiting is dropped first. */
export function playNextMove(state: CoAuthorState): CoAuthorState {
  const start: CoAuthorState = { ...state, keycast: { ...state.keycast, pending: [] } };
  return (nextKeys(state) ?? []).reduce((next, key) => pressKey(next, key).state, start);
}

/** The step the stepper shows, or null when the lab is finished: a finished lab names no key, because no key has anything left to do. */
export function currentStep(state: CoAuthorState): StepId | null {
  return state.move === "finished" ? null : MOVE_SPECS[state.move].step;
}

/**
 * The keys the caption names, written the way the site writes keys: a bracket pair as one word, every other sequence with a space between keys.
 */
export function captionKeysText(state: CoAuthorState): string {
  const keys = state.captionKeys;
  return keys[0] === "]" || keys[0] === "[" ? keys.join("") : keys.join(" ");
}

/** The steps the learner has completed, in order. A step with two moves is done after its second move. */
export function doneSteps(state: CoAuthorState): readonly StepId[] {
  if (state.move === "finished") return STEP_IDS;
  return STEP_IDS.slice(0, STEP_IDS.indexOf(MOVE_SPECS[state.move].step));
}

export interface FileLine {
  readonly id: LineId;
  readonly visible: boolean;
  readonly mark: Mark;
}

function changeOf(id: LineId): ChangeId | null {
  if (CHANGE_LINES.first.includes(id)) return "first";
  return CHANGE_LINES.second.includes(id) ? "second" : null;
}

export function fileLines(state: CoAuthorState): readonly FileLine[] {
  return LINE_IDS.map((id) => {
    const change = changeOf(id);
    if (change === null) return { id, visible: true, mark: "you" };
    const status = state.changes[change];
    if (status === "rejected") return { id, visible: false, mark: "minga" };
    if (status === "kept") return { id, visible: true, mark: "kept" };
    const shared = id === SHARED_LINE || (id === EDIT_LINE && state.edited);
    return { id, visible: true, mark: shared ? "shared" : "minga" };
  });
}
