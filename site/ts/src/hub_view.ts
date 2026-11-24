/* Learn Hub (/learn/): hydrates localStorage completion progress on each lesson card. */

import { getLessonSummary, type LessonId } from "./progress.ts";

const LESSONS: readonly LessonId[] = ["getting-started", "editing", "agents", "elixir", "remote"];

export function mountLearnHub(root: HTMLElement): void {
  let totalDone = 0;
  let totalMissions = 0;

  for (const id of LESSONS) {
    const summary = getLessonSummary(id);
    totalDone += summary.done;
    totalMissions += summary.total;

    const badge = root.querySelector<HTMLElement>(`[data-lesson-progress="${id}"]`);
    if (badge) {
      if (summary.done > 0) {
        badge.textContent = summary.done >= summary.total ? `Done · ${summary.done}/${summary.total}` : `${summary.done}/${summary.total} missions`;
        badge.classList.add("is-progress");
        if (summary.done >= summary.total) badge.classList.add("is-complete");
      } else {
        badge.textContent = `${summary.total} ${summary.total === 1 ? "step" : "missions"}`;
      }
    }
  }

  const overall = root.querySelector<HTMLElement>("[data-hub-overall]");
  if (overall) {
    overall.textContent =
      totalDone > 0
        ? `Local progress: ${totalDone} of ${totalMissions} interactive missions completed`
        : `${totalMissions} hands-on browser missions across 5 lessons · Zero accounts`;
  }
}
