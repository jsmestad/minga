/* Lesson progress for the Minga Learn pages, kept in this browser's localStorage (no accounts, and nothing breaks when storage is off). */

/**
 * The storage key. v1 stored ids from the labs before the lesson rewrites, and several of those ids now mean a different step.
 * Progress under the old key is never read, so it cannot show a lesson as done.
 */
export const STORAGE_KEY = "minga-learn-progress-v2";

export type LessonId = "editing" | "agents" | "elixir" | "remote";

/** The lessons in reading order: Lesson 01 to Lesson 04. */
export const LESSON_ORDER: readonly LessonId[] = ["editing", "agents", "elixir", "remote"];

/**
 * The progress ids of each lesson, in order: one id for each step its lab can complete. The hub counts against this list and a lab records ids from it.
 * A lab that changes its steps changes its list here. Ids left in a visitor's storage from an older lab are not in the list, so they no longer count.
 */
export const LESSON_STEPS: Readonly<Record<LessonId, readonly string[]>> = {
  editing: ["menu", "group", "open_file", "close"],
  agents: ["find", "edit_undo", "reject", "keep"],
  elixir: ["translated", "copied"],
  remote: ["blocked", "edited", "safe"],
};

function isLessonId(lesson: string): lesson is LessonId {
  return Object.hasOwn(LESSON_STEPS, lesson);
}

export interface LessonSummary {
  readonly done: number;
  readonly total: number;
}

/**
 * Counts a lesson's progress in a stored map. Only the lesson's current ids count, each once.
 * An id from an older lab, a lesson that does not exist and a stored value of the wrong shape all count as nothing.
 */
export function summarizeLesson(stored: unknown, lesson: string): LessonSummary {
  if (!isLessonId(lesson)) return { done: 0, total: 0 };
  const steps = LESSON_STEPS[lesson];
  const list: unknown = stored !== null && typeof stored === "object" ? (stored as Record<string, unknown>)[lesson] : undefined;
  const have = new Set(Array.isArray(list) ? list : []);
  return { done: steps.filter((id) => have.has(id)).length, total: steps.length };
}

/** What the hub offers next: a first visit, the lesson to continue, or every lesson done. The page holds the words for each. */
export type HubNext = { readonly kind: "start" } | { readonly kind: "continue"; readonly lesson: LessonId } | { readonly kind: "done" };

/**
 * Picks the hub's next step from a stored map. With no counted step in any lesson, the reader starts at Getting Started.
 * Otherwise the reader continues with the first lesson, in reading order, that is not finished, even when a later lesson has more progress.
 */
export function hubNext(stored: unknown): HubNext {
  const summaries = LESSON_ORDER.map((lesson) => ({ lesson, ...summarizeLesson(stored, lesson) }));
  if (summaries.every((s) => s.done === 0)) return { kind: "start" };
  const unfinished = summaries.find((s) => s.done < s.total);
  return unfinished ? { kind: "continue", lesson: unfinished.lesson } : { kind: "done" };
}

type ProgressMap = Partial<Record<LessonId, string[]>>;

/** The part of the Web Storage API that progress uses. A test passes its own. */
export type ProgressStore = Pick<Storage, "getItem" | "setItem">;

function browserStore(): ProgressStore | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    /* A browser that blocks storage throws on access. */
    return null;
  }
}

/** Reads the progress map under STORAGE_KEY. Missing, blocked or unreadable storage reads as no progress. */
export function readProgress(store: ProgressStore | null = browserStore()): ProgressMap {
  if (!store) return {};
  try {
    const raw = store.getItem(STORAGE_KEY);
    if (!raw) return {};
    const parsed: unknown = JSON.parse(raw);
    if (parsed && typeof parsed === "object") return parsed as ProgressMap;
  } catch {
    /* Ignore storage errors in restricted contexts. */
  }
  return {};
}

/** Records one completed step of a lesson. */
export function completeMission(lesson: LessonId, missionId: string, store: ProgressStore | null = browserStore()): void {
  if (!store) return;
  const map = readProgress(store);
  const next = new Set(Array.isArray(map[lesson]) ? map[lesson] : []);
  next.add(missionId);
  map[lesson] = Array.from(next);
  try {
    store.setItem(STORAGE_KEY, JSON.stringify(map));
  } catch {
    /* Ignore storage errors in restricted contexts. */
  }
}
