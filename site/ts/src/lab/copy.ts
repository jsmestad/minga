/*
 * The lab kit: shared parts for the site's interactive labs.
 *
 *   copy.ts      reads a lab's steps, captions and named strings from the page (this file)
 *   stage.ts     the focusable stage: keys scoped to it, focus kept inside the lab
 *   caption.ts   the one line of narration under the stage
 *   keycast.ts   the pending and recent keys
 *   stepper.ts   the current step and the done count
 *   timeline.ts  timed beats, a prompt with a timeout, Replay, and Next and Back under reduced motion
 *   esc.ts       the one HTML-escape helper
 *
 * Rules every lab follows:
 *   - Visible words live in the page HTML, never in TypeScript. Lab state holds ids. design/tools/site_check.py reads the page, so it checks the copy.
 *   - Build DOM nodes once. Update text, classes and attributes. Never assign innerHTML over a region that holds a control, and never replace a focused node.
 *   - Listen for keys on the stage element only. No lab listens on window or document.
 *
 * The page-copy contract. A lab root holds one ordered list. It is ordinary visible HTML, so it is also the fallback when JavaScript is off:
 *
 *   <ol data-lab-steps>
 *     <li data-step="open">
 *       <p data-lab-instruction>Open the file</p>
 *       <p data-lab-caption="open">The file is open.</p>
 *       <p data-lab-caption="open_wrong">That key does nothing here.</p>
 *     </li>
 *   </ol>
 *
 *   data-step              the step id. Steps keep their document order.
 *   data-lab-instruction   the step's short label. The stepper shows it.
 *   data-lab-caption="id"  one caption. A step holds one or more. Caption ids are unique in the lab. A caption may hold links; the caption line clones its nodes.
 *   data-lab-text="id"     a named string used elsewhere in the stage (a prompt, for example). It may sit anywhere in the lab root.
 *
 * The contract does not use <template>, <script> or attribute values for copy, because the checker does not read them.
 * mountLab reads the copy and adds the class "lab-live" to the root; the stylesheet then hides the list, and the caption line shows one caption at a time.
 *
 * Chrome classes in site/styles.css ("Lab kit"). A lab uses these and adds only its own stage styles:
 *
 *   lab-live               on the root once the lab is mounted (set by mountLab). Hides [data-lab-steps] and shows the live chrome.
 *   lab-head               the row above the stage: lab-labels (lab-title, lab-sim-label) and lab-stepper.
 *   lab-caption            the caption line, directly under the stage.
 *   lab-timeline-controls  the row of timeline buttons under the caption; each button is a lab-control.
 *   lab-keycast            the pending and recent keys. lab-focus-cue is the "click here, then press keys" hint.
 *   is-stage-focused       on the root while focus is inside the stage (set by mountStage).
 *   lab-sr                 text for screen readers only.
 *   [data-lab-stage]       the stage. It shows a focus ring when the keyboard put focus on it.
 */

export interface LabStep {
  readonly id: string;
  readonly instruction: string;
  readonly captionIds: readonly string[];
}

export interface LabCopy {
  readonly steps: readonly LabStep[];
  /** The page element that holds a caption, or null when the page has no caption with that id. */
  caption(id: string): Element | null;
  /** A named string from the page, or "" when the page has none with that id. */
  text(id: string): string;
}

function cleanText(el: Element | null): string {
  return (el?.textContent ?? "").replace(/\s+/g, " ").trim();
}

/** Mounts a lab: reads its copy from the page and marks the root live, so the step list gives way to the caption line. Every lab starts here. */
export function mountLab(root: HTMLElement): LabCopy {
  const copy = readLabCopy(root);
  root.classList.add("lab-live");
  return copy;
}

export function readLabCopy(root: ParentNode): LabCopy {
  const captions = new Map<string, Element>();
  const texts = new Map<string, string>();
  const steps: LabStep[] = [];

  for (const item of root.querySelectorAll<HTMLElement>("[data-lab-steps] > [data-step]")) {
    const captionIds: string[] = [];
    for (const caption of item.querySelectorAll<HTMLElement>("[data-lab-caption]")) {
      const id = caption.dataset.labCaption ?? "";
      if (id === "" || captions.has(id)) continue;
      captions.set(id, caption);
      captionIds.push(id);
    }
    steps.push({
      id: item.dataset.step ?? "",
      instruction: cleanText(item.querySelector("[data-lab-instruction]")),
      captionIds,
    });
  }

  for (const el of root.querySelectorAll<HTMLElement>("[data-lab-text]")) {
    const id = el.dataset.labText ?? "";
    if (id !== "" && !texts.has(id)) texts.set(id, cleanText(el));
  }

  return {
    steps,
    caption: (id) => captions.get(id) ?? null,
    text: (id) => texts.get(id) ?? "",
  };
}
