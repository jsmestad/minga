/* The stepper: which step a lab is on, out of how many, and how many are done. The step labels come from the page (see copy.ts). */

import type { LabStep } from "./copy.ts";

export interface StepperModel {
  /** One-based position of the current step, or 0 when the id is not a step. */
  readonly position: number;
  readonly total: number;
  readonly doneCount: number;
  readonly label: string;
}

export function stepperModel(steps: readonly LabStep[], currentId: string, doneIds: readonly string[] = []): StepperModel {
  const index = steps.findIndex((step) => step.id === currentId);
  const known = new Set(steps.map((step) => step.id));
  return {
    position: index + 1,
    total: steps.length,
    doneCount: new Set(doneIds.filter((id) => known.has(id))).size,
    label: steps[index]?.instruction ?? "",
  };
}

export interface LabStepper {
  update(currentId: string, doneIds?: readonly string[]): void;
}

/** Builds the stepper's nodes once inside the host. Later updates change text only. */
export function mountStepper(host: HTMLElement, steps: readonly LabStep[]): LabStepper {
  const count = document.createElement("span");
  count.className = "lab-stepper-count";
  const label = document.createElement("span");
  label.className = "lab-stepper-label";
  host.replaceChildren(count, label);

  return {
    update(currentId, doneIds = []) {
      const model = stepperModel(steps, currentId, doneIds);
      count.textContent = `${model.doneCount} / ${model.total}`;
      label.textContent = model.label;
      host.dataset.position = String(model.position);
    },
  };
}
