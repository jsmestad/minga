/*
 * View for the Lesson 04 lab: test a shell command against the hook script printed on the page.
 *
 * The page holds every node and every word. This file finds the nodes once, reads the rules from the printed script, and then changes text, classes and attributes. It never rebuilds the command field, never writes to it unless a preset may fill it (see presetFillsField), and starts no timer.
 * The field is an ordinary text input inside a form: Enter submits the form, and no key is captured anywhere.
 */

import { mountCaption } from "./lab/caption.ts";
import { mountLab } from "./lab/copy.ts";
import { mountStage } from "./lab/stage.ts";
import { mountStepper } from "./lab/stepper.ts";
import { completeMission } from "./progress.ts";
import { createVetoState, currentStep, hookPayload, newlyDone, reduceVeto, STEP_IDS, type VetoEvent, type VetoRule } from "./veto_state.ts";

function text(el: Element | null): string {
  return (el?.textContent ?? "").trim();
}

/** The rules as the printed script states them, in script order, with the script line that holds each one. */
function readRules(root: HTMLElement): { rules: VetoRule[]; lines: Map<string, HTMLElement> } {
  const rules: VetoRule[] = [];
  const lines = new Map<string, HTMLElement>();
  for (const line of root.querySelectorAll<HTMLElement>("[data-veto-script] [data-veto-rule]")) {
    const id = line.dataset.vetoRule ?? "";
    const pattern = text(line.querySelector("[data-veto-pattern]"));
    if (id === "" || pattern === "") continue;
    rules.push({ id, pattern, reason: text(line.querySelector("[data-veto-reason]")) });
    lines.set(id, line);
  }
  return { rules, lines };
}

export function mountRemoteLab(root: HTMLElement): void {
  const stageEl = root.querySelector<HTMLElement>("[data-lab-stage]");
  const captionLine = root.querySelector<HTMLElement>("[data-lab-caption-line]");
  const stepperHost = root.querySelector<HTMLElement>("[data-lab-stepper]");
  const form = root.querySelector<HTMLFormElement>("[data-veto-form]");
  const input = root.querySelector<HTMLInputElement>("[data-veto-input]");
  const result = root.querySelector<HTMLElement>("[data-veto-result]");
  const stdin = root.querySelector<HTMLElement>("[data-veto-stdin]");
  const runs = root.querySelector<HTMLElement>("[data-veto-runs]");
  const message = root.querySelector<HTMLElement>("[data-veto-message]");
  const finished = root.querySelector<HTMLElement>("[data-veto-finished]");
  if (!stageEl || !captionLine || !stepperHost || !form || !input || !result || !stdin || !runs || !message || !finished) {
    throw new Error("The hook tester's markup is incomplete");
  }
  const { rules, lines } = readRules(root);
  if (rules.length === 0) throw new Error("The printed hook script has no rules to test");

  const copy = mountLab(root);
  const caption = mountCaption(captionLine, copy);
  const stepper = mountStepper(stepperHost, copy.steps);
  mountStage(root, { stage: stageEl });

  const prefix = text(root.querySelector("[data-veto-prefix]"));
  const verdicts = Array.from(root.querySelectorAll<HTMLElement>("[data-veto-verdict]"));
  const outputs = Array.from(root.querySelectorAll<HTMLElement>("[data-veto-out]"));
  let state = createVetoState(input.value);

  function render(): void {
    // The field is written only when a preset filled it. Text the reader typed is never replaced.
    if (input!.value !== state.field) input!.value = state.field;

    const last = state.last;
    const verdict = last === null ? "none" : last.verdict.allowed ? "allowed" : "blocked";
    result!.dataset.verdict = verdict;
    for (const el of verdicts) el.hidden = el.dataset.vetoVerdict !== verdict;
    runs!.textContent = String(state.runs);
    if (last !== null) stdin!.textContent = hookPayload(last.command);

    const rule = last?.verdict.rule ?? null;
    message!.textContent = rule === null ? "" : `${prefix} ${rule.reason}`;
    for (const el of outputs) el.hidden = el.dataset.vetoOut !== verdict;
    for (const [id, line] of lines) line.classList.toggle("is-matched", id === rule?.id);

    // The run count goes in as the press count, so a run that lands on the same caption is drawn and announced again.
    caption.show(state.caption, "", state.runs);
    const step = currentStep(state);
    stepper.update(step ?? STEP_IDS[STEP_IDS.length - 1]!, state.done);
    // Neither is a control, so swapping them cannot strand focus.
    stepperHost!.hidden = step === null;
    finished!.hidden = step !== null;
  }

  function send(event: VetoEvent): void {
    const before = state;
    state = reduceVeto(state, event, rules);
    for (const step of newlyDone(before, state)) completeMission("remote", step);
    render();
  }

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    send({ type: "run", field: input.value });
    // Some browsers do not focus a button on a pointer click. Focus must not be left on <body>.
    if (!root.contains(document.activeElement)) (event.submitter ?? input).focus({ preventScroll: true });
  });

  for (const preset of root.querySelectorAll<HTMLButtonElement>("[data-veto-preset]")) {
    preset.addEventListener("click", () => {
      send({ type: "preset", command: text(preset), field: input.value });
      if (!root.contains(document.activeElement)) preset.focus({ preventScroll: true });
    });
  }

  render();
}
