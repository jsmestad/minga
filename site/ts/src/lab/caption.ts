/* The one caption line under a lab stage. It shows the caption whose id the lab state names; the words come from the page (see copy.ts). */

import type { LabCopy } from "./copy.ts";

export interface LabCaption {
  /** Shows the caption with this id. The line keeps its nodes when the id did not change. */
  show(id: string): void;
  current(): string;
}

export function mountCaption(line: HTMLElement, copy: LabCopy): LabCaption {
  let shown = "";
  line.setAttribute("aria-live", "polite");
  line.replaceChildren();

  return {
    show(id) {
      if (id === shown) return;
      const source = copy.caption(id);
      if (!source) return;
      shown = id;
      line.dataset.caption = id;
      line.replaceChildren(...Array.from(source.childNodes, (node) => node.cloneNode(true)));
    },
    current: () => shown,
  };
}
