/* Persistent localStorage mission progress for Minga Learn lessons (zero accounts, graceful fallback). */

const STORAGE_KEY = "minga-learn-progress-v1";

export type LessonId = "editing" | "agents" | "elixir" | "remote";

export const LESSON_TOTALS: Record<LessonId, number> = {
  editing: 5,
  agents: 4,
  elixir: 3,
  remote: 3,
};

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

export function getLessonSummary(lesson: LessonId): { done: number; total: number } {
  const total = LESSON_TOTALS[lesson];
  const done = Math.min(total, getCompletedMissions(lesson).size);
  return { done, total };
}
