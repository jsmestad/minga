/*
 * View for the home page demo: a spec becomes a board.
 *
 * The page holds every node and every word. This file finds the nodes once, then changes attributes, classes and text for each frame.
 * It starts no timer of its own: the lab timeline owns the clock, and the stylesheet owns the motion.
 */

import { mountCaption } from "./lab/caption.ts";
import { readLabCopy } from "./lab/copy.ts";
import { mountStage } from "./lab/stage.ts";
import { mountStepper } from "./lab/stepper.ts";
import { bindTimelineControls, createTimeline, prefersReducedMotion } from "./lab/timeline.ts";
import {
  boardCards,
  captionId,
  COLUMNS,
  columnCount,
  frameOf,
  isEdited,
  linkedLine,
  mingaHasEdited,
  promptId,
  reachedBeats,
  SPEC_BOARD_FRAMES,
  specLines,
  stageInView,
  statusWord,
  YOUR_TURN_TIMEOUT_MS,
  type SpecBoardState,
} from "./spec_board_state.ts";

/** Splits a prompt into one node per character, so the stylesheet can type it out and the text can still wrap. */
function typedNodes(text: string): HTMLElement[] {
  return Array.from(text, (char, i) => {
    const span = document.createElement("span");
    span.textContent = char;
    span.style.setProperty("--i", String(i));
    return span;
  });
}

function startWhenInView(stage: HTMLElement, start: () => void): void {
  if (typeof IntersectionObserver !== "function") {
    start();
    return;
  }
  const observer = new IntersectionObserver(
    (entries) => {
      const entry = entries.at(-1);
      if (!entry?.isIntersecting) return;
      const viewport = entry.rootBounds?.height ?? window.innerHeight;
      if (!stageInView(entry.intersectionRatio, entry.intersectionRect.height, viewport)) return;
      // Once only. Scrolling away and back never restarts the demo; Replay does.
      observer.disconnect();
      start();
    },
    { threshold: [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1] },
  );
  observer.observe(stage);
}

export function mountSpecBoardDemo(root: HTMLElement): void {
  const stageEl = root.querySelector<HTMLElement>("[data-lab-stage]");
  const captionLine = root.querySelector<HTMLElement>("[data-lab-caption-line]");
  const stepperHost = root.querySelector<HTMLElement>("[data-lab-stepper]");
  const boardEl = root.querySelector<HTMLElement>("[data-sb-board]");
  if (!stageEl || !captionLine || !stepperHost || !boardEl) return;
  const board: HTMLElement = boardEl;

  const copy = readLabCopy(root);
  const caption = mountCaption(captionLine, copy);
  const stepper = mountStepper(stepperHost, copy.steps);
  mountStage(root, { stage: stageEl });

  const lines = new Map<string, HTMLElement>();
  for (const el of root.querySelectorAll<HTMLElement>("[data-line]")) lines.set(el.dataset.line ?? "", el);
  const cards = new Map<string, HTMLElement>();
  for (const el of root.querySelectorAll<HTMLElement>("[data-card]")) cards.set(el.dataset.card ?? "", el);
  const counts = new Map<string, HTMLElement>();
  for (const el of root.querySelectorAll<HTMLElement>("[data-sb-count]")) counts.set(el.dataset.sbCount ?? "", el);
  const statuses = Array.from(root.querySelectorAll<HTMLElement>("[data-sb-status]"));
  const prompts = Array.from(root.querySelectorAll<HTMLElement>("[data-sb-prompt]"));
  for (const prompt of prompts) prompt.replaceChildren(...typedNodes(copy.text(prompt.dataset.sbPrompt ?? "")));

  function render(state: SpecBoardState): void {
    const frame = frameOf(state);
    root.dataset.beat = frame.beat;
    root.dataset.rewritten = String(mingaHasEdited(state));
    root.dataset.edited = String(isEdited(state));

    const linked = linkedLine(state);
    for (const line of specLines(state)) {
      const el = lines.get(line.id);
      if (!el) continue;
      el.hidden = !line.visible;
      el.dataset.author = line.author;
      el.classList.toggle("is-linked", line.id === linked);
    }

    const onBoard = boardCards(state);
    board.hidden = onBoard === null;
    for (const card of onBoard ?? []) {
      const el = cards.get(card.id);
      if (!el) continue;
      el.dataset.col = card.column;
      el.style.setProperty("--col", String(COLUMNS.indexOf(card.column)));
    }
    for (const column of COLUMNS) {
      const el = counts.get(column);
      if (el) el.textContent = String(columnCount(state, column));
    }

    const status = statusWord(state);
    for (const el of statuses) el.hidden = el.dataset.sbStatus !== status;
    const prompt = promptId(state);
    for (const el of prompts) el.hidden = el.dataset.sbPrompt !== prompt;

    caption.show(captionId(state));
    stepper.update(frame.beat, reachedBeats(state));
  }

  const timeline = createTimeline(SPEC_BOARD_FRAMES, {
    mode: prefersReducedMotion() ? "stepped" : "timed",
    onChange: (state) => {
      render(state);
      syncControls(state);
    },
  });
  const syncControls = bindTimelineControls(timeline, {
    replay: root.querySelector<HTMLButtonElement>("[data-lab-replay]"),
    next: root.querySelector<HTMLButtonElement>("[data-lab-next]"),
    back: root.querySelector<HTMLButtonElement>("[data-lab-back]"),
    answer: root.querySelector<HTMLButtonElement>("[data-lab-answer]"),
  });

  root.dataset.mode = timeline.state().mode;
  root.style.setProperty("--sb-turn-ms", `${YOUR_TURN_TIMEOUT_MS}ms`);
  root.classList.add("lab-live");
  render(timeline.state());
  syncControls(timeline.state());
  startWhenInView(stageEl, () => timeline.send({ type: "start" }));
}
