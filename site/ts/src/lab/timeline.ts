/*
 * The timeline: an ordered list of frames that a lab plays through.
 *
 * Timed mode holds each frame for its time, then moves on. A prompt frame waits for the visitor; when the visitor does nothing for the frame's time,
 * the timeline answers for them. The last frame ends the run, and Replay starts it again.
 *
 * Stepped mode is for visitors who ask for reduced motion. It starts no timer at all. Next and Back move between the frames marked as stops.
 *
 * The reducer is pure. The runner adds the one timer and is the only place a lab's timed demo waits on the clock.
 */

import type { LabStage } from "./stage.ts";

export interface TimelineFrame {
  /** Timed mode: how long the frame holds. For a prompt frame, how long the visitor has before the timeline answers. The last frame ignores it. */
  readonly holdMs: number;
  /** The frame waits for the visitor (or the timeout) instead of only the clock. */
  readonly prompt?: boolean;
  /** Stepped mode halts here. Frames without it are passed over. The first and last frames are always stops. */
  readonly stop?: boolean;
}

export type TimelineMode = "timed" | "stepped";
export type TimelinePhase = "idle" | "holding" | "prompt" | "ended";

export interface TimelineState {
  readonly mode: TimelineMode;
  readonly index: number;
  readonly phase: TimelinePhase;
}

export type TimelineEvent =
  | { readonly type: "start" }
  /** The current frame's time ran out. On a prompt frame this is the timeout fallback. */
  | { readonly type: "elapsed" }
  /** The visitor answered the prompt. */
  | { readonly type: "answer" }
  | { readonly type: "next" }
  | { readonly type: "back" }
  | { readonly type: "replay" };

export function createTimelineState(mode: TimelineMode): TimelineState {
  return { mode, index: 0, phase: "idle" };
}

function isStop(frames: readonly TimelineFrame[], index: number): boolean {
  return index === 0 || index === frames.length - 1 || frames[index]?.stop === true;
}

function enter(frames: readonly TimelineFrame[], mode: TimelineMode, index: number): TimelineState {
  if (index >= frames.length - 1) return { mode, index: Math.max(frames.length - 1, 0), phase: "ended" };
  if (frames[index]?.prompt) return { mode, index, phase: "prompt" };
  return { mode, index, phase: mode === "timed" ? "holding" : "idle" };
}

function nextStop(frames: readonly TimelineFrame[], index: number): number {
  for (let i = index + 1; i < frames.length; i += 1) if (isStop(frames, i)) return i;
  return index;
}

function prevStop(frames: readonly TimelineFrame[], index: number): number {
  for (let i = index - 1; i >= 0; i -= 1) if (isStop(frames, i)) return i;
  return index;
}

export function reduceTimeline(frames: readonly TimelineFrame[], state: TimelineState, event: TimelineEvent): TimelineState {
  const { mode, index, phase } = state;
  switch (event.type) {
    case "start":
      return phase === "idle" && index === 0 ? enter(frames, mode, 0) : state;
    case "elapsed":
      return mode === "timed" && (phase === "holding" || phase === "prompt") ? enter(frames, mode, index + 1) : state;
    case "answer":
      if (phase !== "prompt") return state;
      return enter(frames, mode, mode === "timed" ? index + 1 : nextStop(frames, index));
    case "next":
      return mode === "stepped" ? enter(frames, mode, nextStop(frames, index)) : state;
    case "back":
      return mode === "stepped" ? enter(frames, mode, prevStop(frames, index)) : state;
    case "replay":
      return enter(frames, mode, 0);
  }
}

/** How long the runner waits before it sends "elapsed", or null when no timer may run. Stepped mode always returns null. */
export function timelineTimerMs(frames: readonly TimelineFrame[], state: TimelineState): number | null {
  if (state.mode !== "timed") return null;
  if (state.phase !== "holding" && state.phase !== "prompt") return null;
  return frames[state.index]?.holdMs ?? null;
}

export function canGoBack(state: TimelineState): boolean {
  return state.mode === "stepped" && state.index > 0;
}

export function canGoNext(state: TimelineState): boolean {
  return state.mode === "stepped" && state.phase !== "ended";
}

export interface TimelineClock {
  set(run: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

const BROWSER_CLOCK: TimelineClock = {
  set: (run, ms) => setTimeout(run, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

export interface TimelineOptions {
  readonly mode: TimelineMode;
  readonly onChange: (state: TimelineState, previous: TimelineState) => void;
  readonly clock?: TimelineClock;
}

export interface Timeline {
  state(): TimelineState;
  send(event: TimelineEvent): void;
}

export function createTimeline(frames: readonly TimelineFrame[], options: TimelineOptions): Timeline {
  const clock = options.clock ?? BROWSER_CLOCK;
  let state = createTimelineState(options.mode);
  let timer: unknown = null;

  function send(event: TimelineEvent): void {
    const previous = state;
    state = reduceTimeline(frames, previous, event);
    if (state === previous) return;
    if (timer !== null) clock.clear(timer);
    timer = null;
    const wait = timelineTimerMs(frames, state);
    if (wait !== null) {
      timer = clock.set(() => {
        timer = null;
        send({ type: "elapsed" });
      }, wait);
    }
    options.onChange(state, previous);
  }

  return { state: () => state, send };
}

/** True when the visitor asked the system for reduced motion. A lab picks stepped mode from this once, at mount. */
export function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export interface TimelineControls {
  readonly replay?: HTMLButtonElement | null;
  readonly next?: HTMLButtonElement | null;
  readonly back?: HTMLButtonElement | null;
  /** The control that answers a prompt frame. It shows only while the timeline waits for the visitor. */
  readonly answer?: HTMLButtonElement | null;
}

/**
 * Wires the page's own buttons to a timeline and returns the function that shows the right ones for a state.
 * Replay shows when a run has ended. Next and Back show only in stepped mode. The buttons are never rebuilt; a button with nothing to do is hidden.
 *
 * A state change can hide the button that has focus (the prompt's timeout hides its answer button). Pass the stage, and focus then moves to the
 * next button that is still visible (Next, then Replay, then Back), or to the stage when none is.
 */
export function bindTimelineControls(timeline: Timeline, controls: TimelineControls, stage?: Pick<LabStage, "rescueFocus">): (state: TimelineState) => void {
  controls.replay?.addEventListener("click", () => timeline.send({ type: "replay" }));
  controls.next?.addEventListener("click", () => timeline.send({ type: "next" }));
  controls.back?.addEventListener("click", () => timeline.send({ type: "back" }));
  controls.answer?.addEventListener("click", () => timeline.send({ type: "answer" }));

  const order = [controls.next, controls.replay, controls.back, controls.answer].filter((el): el is HTMLButtonElement => el != null);

  return (state) => {
    const focused = order.find((el) => el === document.activeElement);
    if (controls.replay) controls.replay.hidden = state.phase !== "ended";
    if (controls.next) controls.next.hidden = !canGoNext(state);
    if (controls.back) controls.back.hidden = !canGoBack(state);
    if (controls.answer) controls.answer.hidden = state.phase !== "prompt";
    if (focused?.hidden) stage?.rescueFocus(focused, order);
  };
}
