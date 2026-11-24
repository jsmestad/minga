/* Entrypoint for Minga static site TypeScript interactive islands. */

import { mountArchFaultMap, mountStagedStepper } from "./arch_interactive.ts";
import { mountCoAuthorSim } from "./coauthor_view.ts";
import { mountElixirPlayground, mountElixirTranslator } from "./elixir_lab.ts";
import { highlightStaticShellBlocks } from "./highlight.ts";
import { mountMarksThemeSwitcher } from "./home_interactive.ts";
import { mountLearnHub } from "./hub_view.ts";
import { mountRemoteLab } from "./remote_lab.ts";
import { mountRunbookFilter } from "./runbook_view.ts";
import { mountSandbox } from "./sandbox_view.ts";
import { mountSpecBoardDemo } from "./spec_board_view.ts";

function init(): void {
  const hub = document.querySelector<HTMLElement>("[data-learn-hub]");
  if (hub) mountLearnHub(hub);

  const runbook = document.querySelector<HTMLElement>("[data-runbook-filter]");
  if (runbook) mountRunbookFilter(runbook);

  const sandbox = document.querySelector<HTMLElement>("[data-minga-sandbox]");
  if (sandbox) mountSandbox(sandbox);

  const coauthor = document.querySelector<HTMLElement>("[data-coauthor-sim]");
  if (coauthor) mountCoAuthorSim(coauthor);

  const translator = document.querySelector<HTMLElement>("[data-elixir-translator]");
  if (translator) mountElixirTranslator(translator);

  const playground = document.querySelector<HTMLElement>("[data-elixir-playground]");
  if (playground) mountElixirPlayground(playground);

  const remote = document.querySelector<HTMLElement>("[data-remote-lab]");
  if (remote) mountRemoteLab(remote);

  const specBoard = document.querySelector<HTMLElement>("[data-spec-board-demo]");
  if (specBoard) mountSpecBoardDemo(specBoard);

  const marksTheme = document.querySelector<HTMLElement>("[data-marks-theme-switcher]");
  if (marksTheme) mountMarksThemeSwitcher(marksTheme);

  const archFault = document.querySelector<HTMLElement>("[data-arch-fault-map]");
  if (archFault) mountArchFaultMap(archFault);

  const stagedStep = document.querySelector<HTMLElement>("[data-staged-stepper]");
  if (stagedStep) mountStagedStepper(stagedStep);

  highlightStaticShellBlocks();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
