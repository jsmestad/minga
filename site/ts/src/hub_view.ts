/*
 * Learn hub (/learn/): shows each lesson's progress from this browser, and the one next step.
 * The words are in the page. This file only picks which of them show, by id, and fills in the count of steps done.
 */

import { hubNext, LESSON_ORDER, readProgress, summarizeLesson } from "./progress.ts";

/** The progress badge states the page holds words for: no step done, some steps done, every step done. */
export type BadgeState = "none" | "some" | "all";

export function badgeState(done: number, total: number): BadgeState {
  if (done === 0) return "none";
  return done < total ? "some" : "all";
}

function showOnly(elements: Iterable<HTMLElement>, read: (el: HTMLElement) => string | undefined, id: string): void {
  for (const el of elements) el.hidden = read(el) !== id;
}

export function mountLearnHub(root: HTMLElement): void {
  const stored = readProgress();

  for (const lesson of LESSON_ORDER) {
    const badge = root.querySelector<HTMLElement>(`[data-lesson-progress="${lesson}"]`);
    if (!badge) continue;
    const { done, total } = summarizeLesson(stored, lesson);
    const state = badgeState(done, total);
    for (const slot of badge.querySelectorAll<HTMLElement>("[data-progress-done]")) slot.textContent = String(done);
    showOnly(badge.querySelectorAll<HTMLElement>("[data-progress-state]"), (el) => el.dataset.progressState, state);
    badge.dataset.progress = state;
  }

  const next = hubNext(stored);
  showOnly(root.querySelectorAll<HTMLElement>("[data-hub-next]"), (el) => el.dataset.hubNext, next.kind === "continue" ? next.lesson : next.kind);
}
