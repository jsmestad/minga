/*
 * View for the Lesson 02 lab: you and Minga work in the same file.
 *
 * The page holds every node and every word. This file finds the nodes once, then changes attributes, classes and text for each state.
 * Keys reach the lab through the lab stage only, so the page keeps its own keys whenever the stage does not have focus.
 */

import { mountCaption } from "./lab/caption.ts";
import { mountLab } from "./lab/copy.ts";
import { mountKeycast } from "./lab/keycast.ts";
import { mountStage } from "./lab/stage.ts";
import { mountStepper } from "./lab/stepper.ts";
import { completeMission } from "./progress.ts";
import { captionKeysText, createCoAuthorState, currentStep, doneSteps, fileLines, nextKeys, playNextMove, pressKey, type CoAuthorState } from "./coauthor_state.ts";

export function mountCoAuthorSim(root: HTMLElement): void {
  const stageEl = root.querySelector<HTMLElement>("[data-lab-stage]");
  const captionLine = root.querySelector<HTMLElement>("[data-lab-caption-line]");
  const stepperHost = root.querySelector<HTMLElement>("[data-lab-stepper]");
  const keycastHost = root.querySelector<HTMLElement>("[data-lab-keycast]");
  const playButton = root.querySelector<HTMLButtonElement>("[data-ca-play]");
  const resetButton = root.querySelector<HTMLButtonElement>("[data-ca-reset]");
  if (!stageEl || !captionLine || !stepperHost || !keycastHost || !playButton || !resetButton) return;
  const play: HTMLButtonElement = playButton;

  const copy = mountLab(root);
  const caption = mountCaption(captionLine, copy);
  const stepper = mountStepper(stepperHost, copy.steps);
  const keycast = mountKeycast(keycastHost);

  const lines = new Map<string, HTMLElement>();
  for (const el of root.querySelectorAll<HTMLElement>("[data-line]")) lines.set(el.dataset.line ?? "", el);
  const editTexts = Array.from(root.querySelectorAll<HTMLElement>("[data-ca-text]"));

  let state = createCoAuthorState();

  function render(): void {
    root.dataset.move = state.move;
    for (const line of fileLines(state)) {
      const el = lines.get(line.id);
      if (!el) continue;
      el.hidden = !line.visible;
      el.dataset.author = line.mark;
      el.classList.toggle("is-cursor", line.id === state.cursor);
      for (const word of el.querySelectorAll<HTMLElement>("[data-ca-mark]")) word.hidden = word.dataset.caMark !== line.mark;
    }
    for (const el of editTexts) el.hidden = (el.dataset.caText === "edit") !== state.edited;
    play.hidden = nextKeys(state) === null;
    caption.show(state.caption, captionKeysText(state), state.presses);
    stepper.update(currentStep(state) ?? "", doneSteps(state));
    keycast.update(state.keycast);
  }

  function update(next: CoAuthorState): void {
    const before = doneSteps(state);
    for (const step of doneSteps(next)) {
      if (!before.includes(step)) completeMission("agents", step);
    }
    state = next;
    render();
  }

  mountStage(root, {
    stage: stageEl,
    onKey: (key, event) => {
      // Tab leaves the stage and a Command chord belongs to the browser. The lab leaves both alone and says nothing about them.
      if (event.metaKey || key === "TAB") return false;
      const result = pressKey(state, key);
      update(result.state);
      return result.handled;
    },
  });

  // For a reader with no keyboard: presses the keys the current move waits for, through the same path as a real key press.
  play.addEventListener("click", () => update(playNextMove(state)));
  resetButton.addEventListener("click", () => update(createCoAuthorState()));

  resetButton.hidden = false;
  render();
}
