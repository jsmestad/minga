/*
 * State for the home page demo: a spec becomes a board.
 *
 * The demo is a fixed list of frames on the lab timeline. Everything the view draws is derived from the current frame, and every derived value is an id.
 * The words (spec text, prompts, card titles, captions, state words) live in site/index.html.
 */

import {
  createTimelineState,
  reduceTimeline,
  type TimelineEvent,
  type TimelineFrame,
  type TimelineMode,
  type TimelineState,
} from "./lab/timeline.ts";

export type Beat = "rest" | "ask_edit" | "minga_edits" | "your_turn" | "ask_board" | "board_builds" | "done";
export const BEATS: readonly Beat[] = ["rest", "ask_edit", "minga_edits", "your_turn", "ask_board", "board_builds", "done"];

export type LineId = "title" | "gap_1" | "intro" | "gap_2" | "heading" | "save" | "sync" | "retry" | "status";
export type Author = "you" | "minga" | "shared";
export type CardId = "save" | "sync" | "retry" | "status";
export type Column = "waiting" | "working" | "done";
export type StatusWord = "working" | "done";
export type PromptId = "prompt_edit" | "prompt_board";
export type CaptionId = Beat | "your_turn_done";

export const LINE_IDS: readonly LineId[] = ["title", "gap_1", "intro", "gap_2", "heading", "save", "sync", "retry", "status"];
/** Each card is one requirement line of the spec, so a card and its line share an id. */
export const CARD_IDS: readonly CardId[] = ["save", "sync", "retry", "status"];
export const COLUMNS: readonly Column[] = ["waiting", "working", "done"];

type CardColumns = readonly [Column, Column, Column, Column];

export interface SpecBoardFrame extends TimelineFrame {
  readonly beat: Beat;
  /** The visitor (or the timeout) has made the edit of the "your turn" beat. */
  readonly turnTaken: boolean;
  /** Where each card sits, in CARD_IDS order. Null while the right pane is empty. */
  readonly cards: CardColumns | null;
}

/** How long the visitor has at the "your turn" beat before the edit types itself. */
export const YOUR_TURN_TIMEOUT_MS = 4000;

function frame(beat: Beat, holdMs: number, extra: Partial<Omit<SpecBoardFrame, "beat" | "holdMs">> = {}): SpecBoardFrame {
  return { beat, holdMs, turnTaken: false, cards: null, stop: true, ...extra };
}

function building(cards: CardColumns, stop: boolean): SpecBoardFrame {
  return frame("board_builds", 1100, { turnTaken: true, cards, stop });
}

export const SPEC_BOARD_FRAMES: readonly SpecBoardFrame[] = [
  frame("rest", 1400),
  frame("ask_edit", 3200),
  frame("minga_edits", 4600),
  frame("your_turn", YOUR_TURN_TIMEOUT_MS, { prompt: true }),
  frame("your_turn", 3000, { turnTaken: true }),
  frame("ask_board", 3200, { turnTaken: true }),
  building(["waiting", "waiting", "waiting", "waiting"], false),
  building(["working", "waiting", "waiting", "waiting"], false),
  building(["done", "working", "waiting", "waiting"], false),
  building(["done", "done", "working", "waiting"], true),
  building(["done", "done", "done", "working"], false),
  frame("done", 0, { turnTaken: true, cards: ["done", "done", "done", "done"] }),
];

export type SpecBoardState = TimelineState;
export type SpecBoardEvent = TimelineEvent;

export function createSpecBoardState(mode: TimelineMode): SpecBoardState {
  return createTimelineState(mode);
}

export function reduceSpecBoard(state: SpecBoardState, event: SpecBoardEvent): SpecBoardState {
  return reduceTimeline(SPEC_BOARD_FRAMES, state, event);
}

export function frameOf(state: SpecBoardState): SpecBoardFrame {
  return SPEC_BOARD_FRAMES[state.index] ?? SPEC_BOARD_FRAMES[0]!;
}

function reached(state: SpecBoardState, beat: Beat): boolean {
  return BEATS.indexOf(frameOf(state).beat) >= BEATS.indexOf(beat);
}

/** Minga has added its two requirements and rewritten one. */
export function mingaHasEdited(state: SpecBoardState): boolean {
  return reached(state, "minga_edits");
}

/** The retry count on Minga's line carries the visitor's edit. */
export function isEdited(state: SpecBoardState): boolean {
  return frameOf(state).turnTaken;
}

export interface SpecLine {
  readonly id: LineId;
  readonly author: Author;
  readonly visible: boolean;
}

const MINGA_ADDS: ReadonlySet<LineId> = new Set<LineId>(["retry", "status"]);
const MINGA_WRITES: ReadonlySet<LineId> = new Set<LineId>(["sync", "retry", "status"]);

export function specLines(state: SpecBoardState): readonly SpecLine[] {
  const minga = mingaHasEdited(state);
  const edited = isEdited(state);
  return LINE_IDS.map((id) => {
    if (!minga || !MINGA_WRITES.has(id)) return { id, author: "you", visible: !MINGA_ADDS.has(id) };
    return { id, author: id === "retry" && edited ? "shared" : "minga", visible: true };
  });
}

export interface BoardCard {
  readonly id: CardId;
  readonly column: Column;
}

/** The cards on the board, or null while the right pane is still empty. */
export function boardCards(state: SpecBoardState): readonly BoardCard[] | null {
  const cards = frameOf(state).cards;
  if (!cards) return null;
  return CARD_IDS.map((id, i) => ({ id, column: cards[i]! }));
}

export function columnCount(state: SpecBoardState, column: Column): number {
  return (boardCards(state) ?? []).filter((card) => card.column === column).length;
}

/** The spec line behind the card Minga is working on, so the view can show that a card is a line of the spec. */
export function linkedLine(state: SpecBoardState): LineId | null {
  return boardCards(state)?.find((card) => card.column === "working")?.id ?? null;
}

export function captionId(state: SpecBoardState): CaptionId {
  const { beat, turnTaken } = frameOf(state);
  return beat === "your_turn" && turnTaken ? "your_turn_done" : beat;
}

export function statusWord(state: SpecBoardState): StatusWord | null {
  const { beat } = frameOf(state);
  if (beat === "minga_edits" || beat === "board_builds") return "working";
  return beat === "done" ? "done" : null;
}

/** The prompt shown in the composer, or null when the composer is empty or holds the "your turn" control. */
export function promptId(state: SpecBoardState): PromptId | null {
  const { beat } = frameOf(state);
  if (beat === "ask_edit" || beat === "minga_edits") return "prompt_edit";
  if (beat === "ask_board" || beat === "board_builds" || beat === "done") return "prompt_board";
  return null;
}

/** The beats up to and including the current one, for the stepper's count. */
export function reachedBeats(state: SpecBoardState): readonly Beat[] {
  return BEATS.slice(0, BEATS.indexOf(frameOf(state).beat) + 1);
}

/**
 * Whether enough of the stage is on screen to start. Half of the stage is the rule; a stage taller than the viewport can never show half of itself,
 * so filling half of the viewport counts too.
 */
export function stageInView(visibleRatio: number, visibleHeight: number, viewportHeight: number): boolean {
  return visibleRatio >= 0.5 || (viewportHeight > 0 && visibleHeight >= viewportHeight * 0.5);
}
