/* Entrypoint for Minga static site TypeScript interactive islands. */

import { mountArchFaultMap, mountStagedStepper } from "./arch_interactive.ts";
import { mountCoAuthorSim } from "./coauthor_view.ts";
import { mountElixirPlayground, mountElixirTranslator } from "./elixir_lab.ts";
import { highlightStaticShellBlocks } from "./highlight.ts";
import { mountMarksThemeSwitcher } from "./home_interactive.ts";
import { mountLearnHub } from "./hub_view.ts";
import { mountRemoteLab } from "./remote_lab.ts";
import { mountSandbox } from "./sandbox_view.ts";
import { mountSpecBoardDemo } from "./spec_board_view.ts";

/**
 * Mounts one lab on the first element that matches. A lab that throws falls back to its static figure and step list (class "lab-failed")
 * and is logged; the labs after it still mount.
 */
function mount(selector: string, run: (root: HTMLElement) => void): void {
  const root = document.querySelector<HTMLElement>(selector);
  if (!root) return;
  try {
    run(root);
  } catch (error) {
    root.classList.remove("lab-live");
    root.classList.add("lab-failed");
    console.error(`Lab ${selector} failed to mount`, error);
  }
}

function init(): void {
  mount("[data-learn-hub]", mountLearnHub);
  mount("[data-minga-sandbox]", mountSandbox);
  mount("[data-coauthor-sim]", mountCoAuthorSim);
  mount("[data-elixir-translator]", mountElixirTranslator);
  mount("[data-elixir-playground]", mountElixirPlayground);
  mount("[data-remote-lab]", mountRemoteLab);
  mount("[data-spec-board-demo]", mountSpecBoardDemo);
  mount("[data-marks-theme-switcher]", mountMarksThemeSwitcher);
  mount("[data-arch-fault-map]", mountArchFaultMap);
  mount("[data-staged-stepper]", mountStagedStepper);

  highlightStaticShellBlocks();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
