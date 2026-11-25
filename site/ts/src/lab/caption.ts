/*
 * The one caption line under a lab stage. It shows the caption whose id the lab state names; the words come from the page (see copy.ts).
 *
 * A caption may name the keys just pressed. The page marks the place with data-lab-key and puts stand-in words there ("That key"), so the step list
 * still reads well without JavaScript. The caption line puts the keys in that place, also when the same caption shows again for another key.
 */

import type { LabCopy } from "./copy.ts";

export interface CaptionShown {
  readonly id: string;
  /** The keys the caption names, as shown ("SPC a"). Empty when the caption names none. */
  readonly keys: string;
}

export type CaptionChange = "none" | "keys" | "swap";

/** What the caption line has to do to show `next`: nothing, refill the key slot of the caption it already shows, or swap in another caption. */
export function captionChange(shown: CaptionShown, next: CaptionShown): CaptionChange {
  if (next.id !== shown.id) return "swap";
  return next.keys === shown.keys ? "none" : "keys";
}

export interface LabCaption {
  /** Shows the caption with this id and names `keys` in its key slot, when it has one. The line keeps its nodes when only the keys changed. */
  show(id: string, keys?: string): void;
  current(): string;
}

export function mountCaption(line: HTMLElement, copy: LabCopy): LabCaption {
  let shown: CaptionShown = { id: "", keys: "" };
  line.setAttribute("aria-live", "polite");
  line.replaceChildren();

  const fillKeys = (keys: string): void => {
    if (keys === "") return;
    for (const slot of line.querySelectorAll<HTMLElement>("[data-lab-key]")) slot.textContent = keys;
  };

  return {
    show(id, keys = "") {
      const next: CaptionShown = { id, keys };
      const change = captionChange(shown, next);
      if (change === "none") return;
      if (change === "swap") {
        const source = copy.caption(id);
        if (!source) return;
        line.dataset.caption = id;
        line.replaceChildren(...Array.from(source.childNodes, (node) => node.cloneNode(true)));
      }
      shown = next;
      fillKeys(keys);
    },
    current: () => shown.id,
  };
}
