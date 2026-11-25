/*
 * The lab stage: the one element of a lab that takes keys.
 *
 * - Keys are heard on the stage element only, so the page keeps its own keys (the space bar scrolls) whenever the stage does not have focus.
 * - Focus must never fall to <body> when a control goes away (hidden or disabled), whether a click or a timer removed it. Focus then moves to the next control that is still visible, and to the stage when there is none.
 * - A lab that takes keys also gets focus on its stage after a pointer click on a control, so the next key press lands in the stage. A control worked from the keyboard keeps focus, so it can be pressed again.
 * - The root carries the class "is-stage-focused" while focus is inside the stage, so the stylesheet can show a "click here, then press keys" cue when it is not.
 *
 * - onKey returns true only for a key the lab binds. The stage keeps a bound key from the browser (a Control chord included), never Tab or a Command chord.
 *   A lab still answers an unbound key in its caption and returns false, which is how "every key answers" and "Tab always leaves" hold together.
 *
 * Key names and prefix tracking are pure, so a lab's state tests can drive them without a DOM.
 */

export interface KeyLike {
  readonly key: string;
  readonly ctrlKey?: boolean;
  readonly metaKey?: boolean;
  readonly altKey?: boolean;
  /** KeyboardEvent.getModifierState. Used to tell AltGr typing from a Control and Option chord. */
  getModifierState?(name: string): boolean;
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

const MODIFIER_KEYS: ReadonlySet<string> = new Set([
  "Shift",
  "Control",
  "Alt",
  "AltGraph",
  "Meta",
  "OS",
  "Hyper",
  "Super",
  "Symbol",
  "CapsLock",
  "NumLock",
  "ScrollLock",
  "Fn",
  "Dead",
  "Unidentified",
  "Process",
]);

/** AltGr types a character on many layouts, and some systems report it as Control plus Option. That press is the character, not a chord. */
function typedWithAltGraph(event: KeyLike): boolean {
  return event.getModifierState?.("AltGraph") === true && Array.from(event.key).length === 1;
}

/**
 * On a Mac, Option types a character on many layouts: a German keyboard has no ] key, only Option+6. That press is the character, not a chord.
 * It holds for Option alone (no Control, no Command) with one printable character that is not a letter. Option plus a letter stays a chord.
 */
function typedWithOption(event: KeyLike): boolean {
  if (!event.altKey || event.ctrlKey || event.metaKey) return false;
  return Array.from(event.key).length === 1 && !/[\p{L}\s]/u.test(event.key);
}

/**
 * Names a key press the way the site writes keys: a printable key as itself (Shift is already in the character), named keys in capitals,
 * and Control, Option and Command as the prefixes C-, M- and D-. A press of a modifier alone has no name and returns null.
 */
export function normalizeKey(event: KeyLike): string | null {
  if (MODIFIER_KEYS.has(event.key)) return null;
  const base = NAMED_KEYS[event.key] ?? event.key;
  const typed = typedWithAltGraph(event) || typedWithOption(event);
  const mods = `${event.ctrlKey && !typed ? "C-" : ""}${event.altKey && !typed ? "M-" : ""}${event.metaKey ? "D-" : ""}`;
  return `${mods}${base}`;
}

/**
 * Whether a focused stage keeps this key from the page.
 *
 * - Tab and Shift+Tab always leave the stage, and a Command chord always stays with the browser, even when the lab handled the key.
 * - A Control chord, an Option chord or a function key is kept only when the lab handled it. A lab that teaches Control+J must be able to stop
 *   the browser acting on it; a Control chord the lab does not bind stays a browser shortcut.
 * - Any other key is kept, so the space bar does not scroll the page while the stage has focus.
 */
export function capturesKey(event: KeyLike, handled: boolean): boolean {
  if (event.key === "Tab" || event.metaKey) return false;
  if (handled) return true;
  if (typedWithAltGraph(event) || typedWithOption(event)) return true;
  if (/^F\d+$/.test(event.key)) return false;
  return !(event.ctrlKey || event.altKey);
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

/** The next item after the lost one that is still visible, searching in order and wrapping round. Null when none is. */
export function nextVisible<T>(order: readonly T[], lost: T, isVisible: (item: T) => boolean): T | null {
  const start = order.indexOf(lost);
  for (let i = 1; i <= order.length; i += 1) {
    const candidate = order[(start + i) % order.length] as T;
    if (candidate !== lost && isVisible(candidate)) return candidate;
  }
  return null;
}

export type ClickFocus = "stage" | "rescue" | "stay";

/**
 * Where focus goes after a click on a lab control. A pointer click in a lab that takes keys returns focus to the stage. Otherwise focus stays on the
 * control, unless the control went away; then it is rescued (next visible control, else the stage).
 */
export function focusAfterControlClick(click: { readonly keyed: boolean; readonly pointer: boolean; readonly gone: boolean }): ClickFocus {
  if (click.keyed && click.pointer) return "stage";
  return click.gone ? "rescue" : "stay";
}

export interface StageOptions {
  /** The focusable element. It keeps its identity for the life of the lab. */
  readonly stage: HTMLElement;
  /**
   * Called for each named key pressed in the focused stage, Tab included. Omit it for a lab that takes no keys.
   * Return true only for a key the lab binds. For any other key, update the caption if you like ("that key does nothing here") and return false:
   * every key still gets an answer, and Tab and the browser's own shortcuts keep working.
   */
  readonly onKey?: (key: string, event: KeyboardEvent) => boolean | void;
}

export interface LabStage {
  focus(): void;
  hasFocus(): boolean;
  /**
   * Call when a control that had focus went away. Focus moves to the next visible control and, when there is none, to the stage.
   * The order to search defaults to the lab's controls in document order.
   */
  rescueFocus(lost: HTMLElement, order?: readonly HTMLElement[]): void;
}

const CONTROLS = "button, [data-lab-control]";

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
  const rescueFocus = (lost: HTMLElement, order?: readonly HTMLElement[]): void => {
    const controls = order ?? Array.from(root.querySelectorAll<HTMLElement>(CONTROLS));
    const target = nextVisible(controls, lost, (control) => !isGone(control));
    if (target) target.focus({ preventScroll: true });
    else focus();
  };
  /** Focus sits on something in the lab that is still there, so there is nothing to rescue. */
  const focusIsSafe = (): boolean => {
    const active = document.activeElement;
    return active instanceof HTMLElement && active !== document.body && root.contains(active) && !isGone(active);
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
    const control = (event.target as HTMLElement | null)?.closest<HTMLElement>(CONTROLS);
    if (!control || !root.contains(control)) return;
    const action = focusAfterControlClick({ keyed: onKey !== undefined, pointer: event.detail > 0, gone: isGone(control) });
    if (action === "stage") focus();
    else if (action === "rescue" && !focusIsSafe()) rescueFocus(control);
  });

  syncFocus();
  return { focus, hasFocus: () => stage.contains(document.activeElement), rescueFocus };
}
