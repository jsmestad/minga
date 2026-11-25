/*
 * Reads a lab's copy contract out of a site page for tests, with no DOM. A lab's state test uses it to prove that every id the state can emit
 * (step, caption, named string, or any lab-specific data attribute) has words in the page. See src/lab/copy.ts for the contract.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const SITE_ROOT = fileURLToPath(new URL("../../../", import.meta.url));

export interface PageLab {
  /** The lab root's own HTML, from its opening tag to its matching closing tag. */
  readonly html: string;
  readonly steps: readonly string[];
  readonly captions: readonly string[];
  readonly texts: readonly string[];
  /** Every value of one attribute inside the lab, in document order. */
  attr(name: string): string[];
}

function attrValues(html: string, name: string): string[] {
  return Array.from(html.matchAll(new RegExp(`\\s${name}="([^"]*)"`, "g")), (m) => m[1]!);
}

/** Cuts the element that carries `rootAttr` out of a page. `page` is a path under site/, such as "index.html". */
export function readPageLab(page: string, rootAttr: string): PageLab {
  const source = readFileSync(`${SITE_ROOT}${page}`, "utf8");
  const open = new RegExp(`<([a-z][a-z0-9]*)\\b[^>]*\\s${rootAttr}(?=[\\s=>])[^>]*>`).exec(source);
  if (!open) throw new Error(`${page} has no element with ${rootAttr}`);
  const tag = open[1]!;
  const tags = new RegExp(`<(/?)${tag}\\b[^>]*>`, "g");
  tags.lastIndex = open.index;
  let depth = 0;
  for (let m = tags.exec(source); m; m = tags.exec(source)) {
    depth += m[1] === "/" ? -1 : 1;
    if (depth === 0) {
      const html = source.slice(open.index, m.index + m[0].length);
      return {
        html,
        steps: attrValues(html, "data-step"),
        captions: attrValues(html, "data-lab-caption"),
        texts: attrValues(html, "data-lab-text"),
        attr: (name) => attrValues(html, name),
      };
    }
  }
  throw new Error(`${page}: the <${tag} ${rootAttr}> element is not closed`);
}

/** The ids in `wanted` that the page does not have. Empty means the page covers them all. */
export function missing(wanted: readonly string[], present: readonly string[]): string[] {
  const have = new Set(present);
  return wanted.filter((id) => !have.has(id));
}
