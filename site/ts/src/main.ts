/* Entrypoint for Minga static site TypeScript interactive islands. */

import { mountArchFaultMap, mountStagedStepper } from "./arch_interactive.ts";
import { mountCoAuthorSim } from "./coauthor_view.ts";
import { mountElixirPlayground, mountElixirTranslator } from "./elixir_lab.ts";
import { mountLayerExplorer, mountWorkflowRollbackDemo } from "./extending_interactive.ts";
import { mountHeroTour, mountMarksThemeSwitcher } from "./home_interactive.ts";
import { mountLearnHub } from "./hub_view.ts";
import { mountRemoteLab } from "./remote_lab.ts";
import { mountRunbookFilter } from "./runbook_view.ts";
import { mountSandbox } from "./sandbox_view.ts";
import { mountCompareLens, mountLayoutComparator } from "./why_interactive.ts";

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

  const heroTour = document.querySelector<HTMLElement>("[data-hero-tour]");
  if (heroTour) mountHeroTour(heroTour);

  const marksTheme = document.querySelector<HTMLElement>("[data-marks-theme-switcher]");
  if (marksTheme) mountMarksThemeSwitcher(marksTheme);

  const layoutComp = document.querySelector<HTMLElement>("[data-layout-comparator]");
  if (layoutComp) mountLayoutComparator(layoutComp);

  const compareLens = document.querySelector<HTMLElement>("[data-compare-lens]");
  if (compareLens) mountCompareLens(compareLens);

  const archFault = document.querySelector<HTMLElement>("[data-arch-fault-map]");
  if (archFault) mountArchFaultMap(archFault);

  const stagedStep = document.querySelector<HTMLElement>("[data-staged-stepper]");
  if (stagedStep) mountStagedStepper(stagedStep);

  const layerExp = document.querySelector<HTMLElement>("[data-layer-explorer]");
  if (layerExp) mountLayerExplorer(layerExp);

  const rollbackDemo = document.querySelector<HTMLElement>("[data-workflow-rollback]");
  if (rollbackDemo) mountWorkflowRollbackDemo(rollbackDemo);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
