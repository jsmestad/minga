/*
 * Pure state for the Lesson 04 lab: test a shell command against the hook script printed on the page.
 *
 * The rules are not written here. The view reads each rule's pattern and reason from the script in the page, so the lab tests the script the reader copies.
 * A pattern is a POSIX extended regular expression, limited to the parts that mean the same to grep and to JavaScript: literals, bracket lists with plain ranges, groups, alternation, the * + ? repeats, the two anchors, and a backslash before a dollar sign.
 * The script turns tabs into spaces, then matches with LC_ALL=C grep -Ei, one line at a time. evaluateHook does the same.
 */

export interface VetoRule {
  readonly id: string;
  readonly pattern: string;
  readonly reason: string;
}

export interface HookVerdict {
  readonly allowed: boolean;
  readonly exitCode: 0 | 1;
  /** The first rule that matched, in script order, or null when the hook allowed the command. */
  readonly rule: VetoRule | null;
}

/** The lines grep sees: the shell drops trailing newlines from the command substitution, tr turns each tab into a space, and printf adds one newline back. */
function commandLines(command: string): string[] {
  return command.replace(/\n+$/, "").replaceAll("\t", " ").split("\n");
}

/** What the hook script does with a command: the first rule whose pattern matches any line vetoes it. */
export function evaluateHook(command: string, rules: readonly VetoRule[]): HookVerdict {
  const lines = commandLines(command);
  for (const rule of rules) {
    const pattern = new RegExp(rule.pattern, "i");
    if (lines.some((line) => pattern.test(line))) return { allowed: false, exitCode: 1, rule };
  }
  return { allowed: true, exitCode: 0, rule: null };
}

/** The JSON Minga writes to the hook's stdin for a shell call, laid out for reading. The key names are the public contract in docs/HOOKS.md. */
export function hookPayload(command: string): string {
  return JSON.stringify({ event: "PreToolUse", tool_call_id: "tc_123", tool_name: "shell", arguments: { command } }, null, 2);
}

/** The three steps. They are also the lesson's progress ids: LESSON_STEPS.remote in progress.ts lists the same ids, and a test holds the two together. */
export const STEP_IDS = ["blocked", "edited", "safe"] as const;
export type StepId = (typeof STEP_IDS)[number];

export const CAPTION_IDS = [
  "rest",
  "empty",
  "allowed_first",
  "blocked",
  "still_blocked",
  "allowed_other",
  "edited",
  "blocked_late",
  "safe_same",
  "safe",
  "free_blocked",
  "free_allowed",
] as const;
export type CaptionId = (typeof CAPTION_IDS)[number];

export interface VetoRun {
  readonly command: string;
  readonly verdict: HookVerdict;
}

export interface VetoState {
  readonly done: readonly StepId[];
  readonly caption: CaptionId;
  /** What the command field holds after the last event. The lab changes it only when a preset fills a field the reader has not typed in. */
  readonly field: string;
  /** The last text the lab itself put in the field. Text that differs from it is the reader's, and the lab never replaces it. */
  readonly labValue: string;
  readonly runs: number;
  readonly last: VetoRun | null;
  /** The command of the latest vetoed run. */
  readonly lastBlocked: string | null;
  /** The command that finished the "edited" step. */
  readonly passed: string | null;
}

export type VetoEvent =
  /** The reader pressed Enter in the field or pressed the run button. */
  | { readonly type: "run"; readonly field: string }
  /** The reader pressed a preset. `field` is what the command field holds at that moment. */
  | { readonly type: "preset"; readonly command: string; readonly field: string };

export function createVetoState(initialField: string): VetoState {
  return { done: [], caption: "rest", field: initialField, labValue: initialField, runs: 0, last: null, lastBlocked: null, passed: null };
}

/** The step the reader is on, or null when all three are done. */
export function currentStep(state: VetoState): StepId | null {
  return STEP_IDS.find((id) => !state.done.includes(id)) ?? null;
}

/** A preset may fill the field only when the reader has typed nothing of their own there. */
export function presetFillsField(field: string, labValue: string): boolean {
  return field.trim() === "" || field === labValue;
}

function firstWord(command: string): string {
  return command.trim().split(/ +/)[0]?.toLowerCase() ?? "";
}

/** An edit of the blocked command still runs the same program. A different program is a different command, not an edit. */
export function editsBlockedCommand(command: string, blocked: string | null): boolean {
  return blocked !== null && firstWord(command) !== "" && firstWord(command) === firstWord(blocked);
}

interface Outcome {
  readonly caption: CaptionId;
  readonly completes?: StepId;
}

function outcome(state: VetoState, command: string, verdict: HookVerdict, typed: boolean): Outcome {
  switch (currentStep(state)) {
    case "blocked":
      return verdict.allowed ? { caption: "allowed_first" } : { caption: "blocked", completes: "blocked" };
    case "edited":
      if (!verdict.allowed) return { caption: "still_blocked" };
      return typed && editsBlockedCommand(command, state.lastBlocked) ? { caption: "edited", completes: "edited" } : { caption: "allowed_other" };
    case "safe":
      if (!verdict.allowed) return { caption: "blocked_late" };
      return command.trim() === state.passed?.trim() ? { caption: "safe_same" } : { caption: "safe", completes: "safe" };
    case null:
      return { caption: verdict.allowed ? "free_allowed" : "free_blocked" };
  }
}

function run(state: VetoState, command: string, rules: readonly VetoRule[], typed: boolean): VetoState {
  if (command.trim() === "") return { ...state, caption: "empty" };
  const verdict = evaluateHook(command, rules);
  const result = outcome(state, command, verdict, typed);
  return {
    ...state,
    caption: result.caption,
    done: result.completes ? [...state.done, result.completes] : state.done,
    runs: state.runs + 1,
    last: { command, verdict },
    lastBlocked: verdict.allowed ? state.lastBlocked : command,
    passed: result.completes === "edited" ? command : state.passed,
  };
}

export function reduceVeto(state: VetoState, event: VetoEvent, rules: readonly VetoRule[]): VetoState {
  if (event.type === "run") return run({ ...state, field: event.field }, event.field, rules, true);
  const fills = presetFillsField(event.field, state.labValue);
  const next: VetoState = fills ? { ...state, field: event.command, labValue: event.command } : { ...state, field: event.field };
  return run(next, event.command, rules, false);
}

/** The steps this event finished, so the view records only real completions. */
export function newlyDone(before: VetoState, after: VetoState): StepId[] {
  return after.done.filter((id) => !before.done.includes(id));
}
