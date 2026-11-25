/*
 * The one caption line under a lab stage. It shows the caption whose id the lab state names; the words come from the page (see copy.ts).
 *
 * A caption may name the keys just pressed. The page marks the place with data-lab-key and puts stand-in words there ("That key"), so the step list still reads well without JavaScript.
 * The caption line puts the keys in that place, also when the same caption shows again for another key.
 *
 * The line is a live region that is read whole (aria-atomic), so a screen reader says the full caption when only the key in it changed.
 * A lab that takes keys passes its count of key presses. A press that leaves the caption and the keys as they were then draws the caption again, so the same key pressed twice is still answered and announced.
 */

import type { LabCopy } from "./copy.ts";

export interface CaptionShown {
  readonly id: string;
  /** The keys the caption names, as shown ("SPC a"). Empty when the caption names none. */
  readonly keys: string;
  /** How many keys the lab has taken so far. A lab that takes no keys leaves it at 0. */
  readonly press: number;
}

export type CaptionChange = "none" | "keys" | "render";

/**
 * What the caption line has to do to show `next`.
 *
 * - "render": draw the caption from the page's copy, then name the keys. For another caption, for a new key press that changed nothing else, and for keys that went away (the page's stand-in words come back).
 * - "keys": refill the key slot of the caption it already shows.
 * - "none": nothing.
 */
export function captionChange(shown: CaptionShown, next: CaptionShown): CaptionChange {
  if (next.id !== shown.id || next.press !== shown.press) return "render";
  if (next.keys === shown.keys) return "none";
  return next.keys === "" ? "render" : "keys";
}

export interface LabCaption {
  /**
   * Shows the caption with this id and names `keys` in its key slot, when it has one. The line keeps its nodes when only the keys changed.
   * `press` is the lab's count of key presses; pass it so that a repeated key draws the caption again.
   */
  show(id: string, keys?: string, press?: number): void;
  current(): string;
}

export function mountCaption(line: HTMLElement, copy: LabCopy): LabCaption {
  let shown: CaptionShown = { id: "", keys: "", press: 0 };
  line.setAttribute("aria-live", "polite");
  line.setAttribute("aria-atomic", "true");
  line.replaceChildren();

  const fillKeys = (keys: string): void => {
    if (keys === "") return;
    for (const slot of line.querySelectorAll<HTMLElement>("[data-lab-key]")) slot.textContent = keys;
  };

  return {
    show(id, keys = "", press = 0) {
      const next: CaptionShown = { id, keys, press };
      const change = captionChange(shown, next);
      if (change === "none") return;
      if (change === "render") {
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
