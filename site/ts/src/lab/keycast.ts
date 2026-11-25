/* The keycast: the keys a lab is still waiting on and the last sequences it saw. Pure state plus a renderer that keeps its nodes. */

import { displayKeys, type PrefixStep } from "./stage.ts";

export interface KeycastState {
  readonly pending: readonly string[];
  /** Finished sequences, newest last. */
  readonly recent: readonly (readonly string[])[];
}

export const KEYCAST_RECENT_LIMIT = 3;

export function createKeycast(): KeycastState {
  return { pending: [], recent: [] };
}

/** Records the result of one key press. A pending key waits; a matched or unknown sequence moves to the recent list. */
export function keycastPush(state: KeycastState, step: PrefixStep, limit: number = KEYCAST_RECENT_LIMIT): KeycastState {
  if (step.status === "pending") return { pending: step.pending, recent: state.recent };
  return { pending: [], recent: [...state.recent, step.keys].slice(-limit) };
}

/** One sequence as the keycast shows it: each key in its display form (the Escape key reads "esc", Control+J reads as the glyph and the letter). */
export function keycastText(keys: readonly string[]): string {
  return displayKeys(keys);
}

export interface LabKeycast {
  update(state: KeycastState): void;
}

/**
 * Builds the keycast nodes once inside the host: one element for each recent sequence, then one for the pending keys.
 * Each sequence has its own element, so two sequences never read as one. Later updates change text and visibility only.
 */
export function mountKeycast(host: HTMLElement, limit: number = KEYCAST_RECENT_LIMIT): LabKeycast {
  const recent = Array.from({ length: limit }, () => {
    const el = document.createElement("span");
    el.className = "lab-keycast-recent";
    el.hidden = true;
    return el;
  });
  const pending = document.createElement("span");
  pending.className = "lab-keycast-pending";
  host.replaceChildren(...recent, pending);

  return {
    update(state) {
      const shown = state.recent.slice(-limit);
      recent.forEach((el, i) => {
        const keys = shown[i];
        el.hidden = keys === undefined;
        el.textContent = keys ? keycastText(keys) : "";
      });
      pending.textContent = keycastText(state.pending);
      pending.hidden = state.pending.length === 0;
      host.classList.toggle("is-pending", state.pending.length > 0);
    },
  };
}
