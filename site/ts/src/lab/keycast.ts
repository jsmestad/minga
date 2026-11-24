/* The keycast: the keys a lab is still waiting on and the last sequences it saw. Pure state plus a renderer that keeps its nodes. */

import type { PrefixStep } from "./stage.ts";

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

export function keycastText(keys: readonly string[]): string {
  return keys.join(" ");
}

export interface LabKeycast {
  update(state: KeycastState): void;
}

/** Builds the two keycast nodes once inside the host. Later updates change text and one class. */
export function mountKeycast(host: HTMLElement): LabKeycast {
  const recent = document.createElement("span");
  recent.className = "lab-keycast-recent";
  const pending = document.createElement("span");
  pending.className = "lab-keycast-pending";
  host.replaceChildren(recent, pending);

  return {
    update(state) {
      recent.textContent = state.recent.map(keycastText).join("  ");
      pending.textContent = keycastText(state.pending);
      host.classList.toggle("is-pending", state.pending.length > 0);
    },
  };
}
