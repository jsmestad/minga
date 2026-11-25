/* Persistent localStorage mission progress for Minga Learn lessons (zero accounts, graceful fallback). */

const STORAGE_KEY = "minga-learn-progress-v1";

export type LessonId = "editing" | "agents" | "elixir" | "remote";

/**
 * The progress ids of each lesson, in order: one id for each step or mission its lab can complete. The hub counts against this list and a lab records ids from it.
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

type ProgressMap = Partial<Record<LessonId, string[]>>;

function readMap(): ProgressMap {
  if (typeof window === "undefined") return {};
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    const parsed: unknown = JSON.parse(raw);
    if (parsed && typeof parsed === "object") {
      return parsed as ProgressMap;
    }
  } catch {
    /* Ignore storage errors in restricted contexts. */
  }
  return {};
}

function writeMap(map: ProgressMap): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(map));
  } catch {
    /* Ignore storage errors in restricted contexts. */
  }
}

export function getCompletedMissions(lesson: LessonId): Set<string> {
  const list = readMap()[lesson];
  return new Set(Array.isArray(list) ? list : []);
}

export function completeMission(lesson: LessonId, missionId: string): Set<string> {
  const map = readMap();
  const next = new Set(Array.isArray(map[lesson]) ? map[lesson] : []);
  next.add(missionId);
  map[lesson] = Array.from(next);
  writeMap(map);
  return next;
}

export function clearLessonProgress(lesson: LessonId): void {
  const map = readMap();
  delete map[lesson];
  writeMap(map);
}

export function getLessonSummary(lesson: LessonId): LessonSummary {
  return summarizeLesson(readMap(), lesson);
}
