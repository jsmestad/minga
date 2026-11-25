/*
 * View for the Lesson 02 lab: find a command through the leader menu.
 *
 * The page holds every node and every word: the files, one menu panel for each group, the switcher and the captions.
 * This file finds the nodes once, then shows and hides them for each state.
 * The menu and the switcher sit above the status line and take no room in the layout, so opening one moves nothing.
 * Keys reach the lab through the lab stage only, so the page keeps its own keys whenever the stage does not have focus.
 */

import { mountCaption } from "./lab/caption.ts";
import { mountLab } from "./lab/copy.ts";
import { mountKeycast } from "./lab/keycast.ts";
import { mountStage } from "./lab/stage.ts";
import { mountStepper } from "./lab/stepper.ts";
import { completeMission } from "./progress.ts";
import { captionKeysText, createSandboxState, currentStep, doneSteps, FILE_IDS, LEADER, nextKey, openMenu, openRow, playNextKey, pressKey, surface, type SandboxState } from "./sandbox_state.ts";

export function mountSandbox(root: HTMLElement): void {
  const stageEl = root.querySelector<HTMLElement>("[data-lab-stage]");
  const captionLine = root.querySelector<HTMLElement>("[data-lab-caption-line]");
  const stepperHost = root.querySelector<HTMLElement>("[data-lab-stepper]");
  const keycastHost = root.querySelector<HTMLElement>("[data-lab-keycast]");
  const playButton = root.querySelector<HTMLButtonElement>("[data-lk-play]");
  const resetButton = root.querySelector<HTMLButtonElement>("[data-lk-reset]");
  const menuHost = root.querySelector<HTMLElement>("[data-lk-menus]");
  const switcherHost = root.querySelector<HTMLElement>("[data-lk-switcher]");
  if (!stageEl || !captionLine || !stepperHost || !keycastHost || !playButton || !resetButton || !menuHost || !switcherHost) return;
  const play: HTMLButtonElement = playButton;
  const menus: HTMLElement = menuHost;
  const switcher: HTMLElement = switcherHost;

  const copy = mountLab(root);
  const caption = mountCaption(captionLine, copy);
  const stepper = mountStepper(stepperHost, copy.steps);
  const keycast = mountKeycast(keycastHost);

  const panels = Array.from(root.querySelectorAll<HTMLElement>("[data-menu]"));
  const fileParts = Array.from(root.querySelectorAll<HTMLElement>("[data-file]"));
  const rows = Array.from(root.querySelectorAll<HTMLElement>("[data-switch-row]"));

  const menuRows = Array.from(root.querySelectorAll<HTMLElement>("[data-menu] [data-key]"));
  /** The keys of a menu row. One row may stand for several keys (the four pins). */
  const rowKeys = (row: HTMLElement): string[] => (row.dataset.key ?? "").split(" ");
  const rowIndex = (row: HTMLElement): number => FILE_IDS.findIndex((id) => id === row.dataset.switchRow);

  let state = createSandboxState();

  function render(): void {
    const menu = openMenu(state);
    root.dataset.surface = surface(state);
    menus.hidden = menu === null;
    for (const panel of panels) panel.hidden = panel.dataset.menu !== menu;
    // The row of the key the current step waits for carries a mark, so the eye finds it without the caption.
    const next = menu === null ? null : nextKey(state);
    for (const row of menuRows) row.classList.toggle("is-next", next !== null && !row.closest("[hidden]") && rowKeys(row).includes(next));
    switcher.hidden = state.switcher === null;
    for (const row of rows) row.classList.toggle("is-selected", rowIndex(row) === state.switcher);
    for (const part of fileParts) part.hidden = part.dataset.file !== state.file;
    play.hidden = nextKey(state) === null;
    caption.show(state.caption, captionKeysText(state), state.presses);
    stepper.update(currentStep(state) ?? "", doneSteps(state));
    keycast.update(state.keycast);
  }

  function update(next: SandboxState): void {
    const before = doneSteps(state);
    for (const step of doneSteps(next)) {
      if (!before.includes(step)) completeMission("editing", step);
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

  // The mouse path: a click on a menu row presses that row's key, a click on a file row opens it, and a click on the mode pill opens the menu, as in Minga.
  stageEl.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    const row = target?.closest<HTMLElement>("[data-switch-row]");
    if (row && state.switcher !== null) {
      update(openRow(state, rowIndex(row)));
      return;
    }
    const keyed = target?.closest<HTMLElement>("[data-key]");
    const key = keyed ? rowKeys(keyed)[0] : undefined;
    if (key === undefined) return;
    if (key === LEADER && surface(state) !== "file" && !target?.closest("[data-menu]")) return;
    update(pressKey(state, key).state);
  });

  // For a reader with no keyboard: presses the key the current step waits for, through the same path as a real key press.
  play.addEventListener("click", () => update(playNextKey(state)));
  resetButton.addEventListener("click", () => update(createSandboxState()));

  resetButton.hidden = false;
  render();
}
