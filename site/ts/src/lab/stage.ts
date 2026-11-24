/*
 * The lab stage: the one element of a lab that takes keys.
 *
 * - Keys are heard on the stage element only, so the page keeps its own keys (the space bar scrolls) whenever the stage does not have focus.
 * - A click on a lab control must not leave focus on <body>. A lab that takes keys gets focus back on its stage after every control click. A lab that takes no keys gets it back only when the clicked control went away (hidden or disabled).
 * - The root carries the class "is-stage-focused" while focus is inside the stage, so the stylesheet can show a "click here, then press keys" cue when it is not.
 *
 * Key names and prefix tracking are pure, so a lab's state tests can drive them without a DOM.
 */

export interface KeyLike {
  readonly key: string;
  readonly ctrlKey?: boolean;
  readonly metaKey?: boolean;
  readonly altKey?: boolean;
}

const NAMED_KEYS: Readonly<Record<string, string>> = {
  " ": "SPC",
  Spacebar: "SPC",
  Escape: "ESC",
  Enter: "RET",
  Tab: "TAB",
  Backspace: "DEL",
  ArrowLeft: "LEFT",
  ArrowRight: "RIGHT",
  ArrowUp: "UP",
  ArrowDown: "DOWN",
};

const MODIFIER_KEYS: ReadonlySet<string> = new Set(["Shift", "Control", "Alt", "Meta", "CapsLock", "Fn", "Dead", "Unidentified", "Process"]);

/**
 * Names a key press the way the site writes keys: a printable key as itself (Shift is already in the character), named keys in capitals,
 * and Control, Option and Command as the prefixes C-, M- and D-. A press of a modifier alone has no name and returns null.
 */
export function normalizeKey(event: KeyLike): string | null {
  if (MODIFIER_KEYS.has(event.key)) return null;
  const base = NAMED_KEYS[event.key] ?? event.key;
  const mods = `${event.ctrlKey ? "C-" : ""}${event.altKey ? "M-" : ""}${event.metaKey ? "D-" : ""}`;
  return `${mods}${base}`;
}

/**
 * Whether a focused stage keeps this key from the page. Tab always leaves the stage, and browser shortcuts (Control or Command chords, function keys)
 * stay with the browser unless the lab handled the key.
 */
export function capturesKey(event: KeyLike, handled: boolean): boolean {
  if (handled) return true;
  if (event.key === "Tab" || /^F\d+$/.test(event.key)) return false;
  return !(event.ctrlKey || event.metaKey || event.altKey);
}

export type PrefixStatus = "pending" | "matched" | "unknown";

export interface PrefixStep {
  readonly status: PrefixStatus;
  /** The keys still waiting for a next key. Empty unless the status is "pending". */
  readonly pending: readonly string[];
  /** The whole sequence this press completed, extended or failed. */
  readonly keys: readonly string[];
}

function startsWith(sequence: readonly string[], prefix: readonly string[]): boolean {
  return prefix.length <= sequence.length && prefix.every((key, i) => sequence[i] === key);
}

/**
 * Feeds one key into a set of key sequences. A full sequence wins over a longer one that starts the same way.
 * A key that fits no sequence returns "unknown" and clears the pending keys, so the lab can say so in its caption.
 */
export function stepPrefix(sequences: readonly (readonly string[])[], pending: readonly string[], key: string): PrefixStep {
  const keys = [...pending, key];
  if (sequences.some((sequence) => sequence.length === keys.length && startsWith(sequence, keys))) {
    return { status: "matched", pending: [], keys };
  }
  if (sequences.some((sequence) => startsWith(sequence, keys))) {
    return { status: "pending", pending: keys, keys };
  }
  return { status: "unknown", pending: [], keys };
}

export interface StageOptions {
  /** The focusable element. It keeps its identity for the life of the lab. */
  readonly stage: HTMLElement;
  /** Called for each named key pressed in the focused stage. Return true when the lab handled it. Omit it for a lab that takes no keys. */
  readonly onKey?: (key: string, event: KeyboardEvent) => boolean | void;
}

export interface LabStage {
  focus(): void;
  hasFocus(): boolean;
}

function isGone(control: HTMLElement): boolean {
  return !control.isConnected || control.closest("[hidden]") !== null || control.matches(":disabled");
}

export function mountStage(root: HTMLElement, options: StageOptions): LabStage {
  const { stage, onKey } = options;
  // A stage that takes keys is a tab stop. One that only receives rescued focus is not.
  stage.tabIndex = onKey ? 0 : -1;

  const focus = (): void => stage.focus({ preventScroll: true });
  const syncFocus = (): void => {
    root.classList.toggle("is-stage-focused", stage.contains(document.activeElement));
  };

  stage.addEventListener("focusin", syncFocus);
  stage.addEventListener("focusout", () => queueMicrotask(syncFocus));

  if (onKey) {
    stage.addEventListener("keydown", (event) => {
      if (event.target !== stage && (event.target as HTMLElement).closest("button, a, input, textarea, select")) return;
      const key = normalizeKey(event);
      if (key === null) return;
      const handled = onKey(key, event) === true;
      if (capturesKey(event, handled)) event.preventDefault();
    });
  }

  // Control handlers run first (they sit on the control or below the root), so by now the lab has redrawn and a control may be hidden.
  root.addEventListener("click", (event) => {
    const control = (event.target as HTMLElement | null)?.closest<HTMLElement>("button, [data-lab-control]");
    if (!control || !root.contains(control)) return;
    if (onKey || isGone(control)) focus();
  });

  syncFocus();
  return { focus, hasFocus: () => stage.contains(document.activeElement) };
}
