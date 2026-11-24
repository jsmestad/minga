/* Architecture demos. All visible copy lives in site/architecture.html; this file holds state, ids and code rows only.
   1. Fault simulation: the same keys in a same-loop editor and in Minga while a tool is slow or crashes.
   2. Staged edit stepper: one edit from read to publish, with a clean and a same-line outcome. */

import { renderElixirLineDom } from "./highlight.ts";

export type FaultKind = "slow_server" | "parser_crash";

/** Names the caption, badges and footers the page shows. Each value matches a `data-step` and `data-iso-show` key in the page. */
export type IsolationView = "rest" | "slow-during" | "slow-after" | "crash-during" | "crash-after";

export type FaultButtonLabel = "start" | "next" | "again";

export interface IsolationSimState {
  readonly fault: FaultKind | null;
  readonly view: IsolationView;
  readonly remainingMs: number;
  readonly mingaText: string;
  readonly legacyText: string;
  readonly legacyQueued: number;
  readonly legacyDead: boolean;
}

export const ISOLATION_BASE_LINE = "def retry_after(429), do: 250";
export const ISOLATION_TYPED = " # retry";

const SLOW_SERVER_MS = 3000;
const PARSER_RESTART_MS = 2700;
const TYPE_INTERVAL_MS = 300;
const TICK_MS = 100;

export function createIsolationSimState(): IsolationSimState {
  return {
    fault: null,
    view: "rest",
    remainingMs: 0,
    mingaText: ISOLATION_BASE_LINE,
    legacyText: ISOLATION_BASE_LINE,
    legacyQueued: 0,
    legacyDead: false,
  };
}

/** Starts a fault from a fresh line, so a second run never inherits text from the first. */
export function triggerIsolationFault(kind: FaultKind): IsolationSimState {
  const fresh = createIsolationSimState();
  if (kind === "slow_server") {
    return { ...fresh, fault: kind, view: "slow-during", remainingMs: SLOW_SERVER_MS };
  }
  return { ...fresh, fault: kind, view: "crash-during", remainingMs: PARSER_RESTART_MS, legacyText: "", legacyDead: true };
}

/** One key reaches both editors. Minga always draws it; the same-loop editor queues it while frozen and drops it once dead. */
export function applyTypedChar(state: IsolationSimState, ch: string): IsolationSimState {
  const mingaText = state.mingaText + ch;
  if (state.legacyDead) return { ...state, mingaText };
  if (state.view === "slow-during") {
    return { ...state, mingaText, legacyQueued: state.legacyQueued + ch.length };
  }
  return { ...state, mingaText, legacyText: state.legacyText + ch };
}

export function applyTypedText(state: IsolationSimState, text: string): IsolationSimState {
  let next = state;
  for (const ch of text) next = applyTypedChar(next, ch);
  return next;
}

export function tickIsolationSim(state: IsolationSimState, deltaMs: number): IsolationSimState {
  if (state.remainingMs <= 0) return state;
  const remainingMs = Math.max(0, state.remainingMs - deltaMs);
  if (remainingMs > 0) return { ...state, remainingMs };
  if (state.fault === "slow_server") {
    return { ...state, view: "slow-after", remainingMs: 0, legacyText: state.mingaText, legacyQueued: 0 };
  }
  return { ...state, view: "crash-after", remainingMs: 0 };
}

/** Jumps to the end of the running fault. The reduced-motion path uses this instead of timers. */
export function finishIsolationFault(state: IsolationSimState): IsolationSimState {
  return tickIsolationSim(state, state.remainingMs);
}

export function faultButtonLabel(state: IsolationSimState, kind: FaultKind, reducedMotion: boolean): FaultButtonLabel {
  if (state.fault !== kind) return "start";
  if (state.remainingMs > 0) return reducedMotion ? "next" : "start";
  return "again";
}

export type StagedStep = 1 | 2 | 3 | 4;

/** Matches a `data-step` and `data-st-show` key in the page. */
export type StagedViewKey = "1" | "2" | "3-clean" | "3-conflict" | "4-clean" | "4-conflict";

export interface StagedPipelineState {
  readonly step: StagedStep;
  readonly conflictMode: boolean;
}

export interface StagedCodeRow {
  readonly ln: number;
  readonly kind: "normal" | "add" | "del" | "you";
  readonly code: string;
}

export interface StagedViewSnapshot {
  readonly view: StagedViewKey;
  readonly rows: readonly StagedCodeRow[];
}

const BASE_12 = "def classify(status) when status >= 500, do: :retry";
const MINGA_12 = "def classify(status) when status == 429 or status >= 500, do: :retry";
const YOUR_12 = "def classify(status) when status >= 500, do: :backoff";
const BASE_13 = "def classify(_status), do: :fatal";
const BASE_15 = "def timeout_ms, do: 5_000";
const YOUR_15 = "def timeout_ms, do: 15_000";

export function createStagedPipelineState(): StagedPipelineState {
  return { step: 1, conflictMode: false };
}

export function stagedViewKey(state: StagedPipelineState): StagedViewKey {
  if (state.step === 1) return "1";
  if (state.step === 2) return "2";
  const outcome = state.conflictMode ? "conflict" : "clean";
  return state.step === 3 ? `3-${outcome}` : `4-${outcome}`;
}

/** Next from the last step starts over with the default outcome; Back from the first step stays put. */
export function stepStagedPipeline(state: StagedPipelineState, direction: "next" | "back"): StagedPipelineState {
  if (direction === "next") {
    if (state.step === 4) return createStagedPipelineState();
    return { ...state, step: (state.step + 1) as StagedStep };
  }
  if (state.step === 1) return state;
  return { ...state, step: (state.step - 1) as StagedStep };
}

function stagedRows(view: StagedViewKey): readonly StagedCodeRow[] {
  const tail: readonly StagedCodeRow[] = [
    { ln: 13, kind: "normal", code: BASE_13 },
    { ln: 14, kind: "normal", code: "" },
  ];
  const base15: StagedCodeRow = { ln: 15, kind: "normal", code: BASE_15 };
  const your15: StagedCodeRow = { ln: 15, kind: "you", code: YOUR_15 };

  switch (view) {
    case "1":
      return [{ ln: 12, kind: "normal", code: BASE_12 }, ...tail, base15];
    case "2":
      return [{ ln: 12, kind: "del", code: BASE_12 }, { ln: 12, kind: "add", code: MINGA_12 }, ...tail, base15];
    case "3-clean":
      return [{ ln: 12, kind: "normal", code: BASE_12 }, ...tail, your15];
    case "3-conflict":
      return [{ ln: 12, kind: "you", code: YOUR_12 }, ...tail, base15];
    case "4-clean":
      return [{ ln: 12, kind: "add", code: MINGA_12 }, ...tail, your15];
    case "4-conflict":
      return [{ ln: 12, kind: "you", code: YOUR_12 }, { ln: 12, kind: "add", code: MINGA_12 }, ...tail, base15];
  }
}

export function computeStagedSnapshot(state: StagedPipelineState): StagedViewSnapshot {
  const view = stagedViewKey(state);
  return { view, rows: stagedRows(view) };
}

function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

/** Shows the elements whose space-separated `attr` list names `key` and hides the rest. Elements stay in the document, so a focused control is never replaced. */
function showOnly(root: HTMLElement, attr: string, key: string): void {
  for (const el of root.querySelectorAll<HTMLElement>(`[${attr}]`)) {
    const keys = (el.getAttribute(attr) ?? "").split(/\s+/);
    el.hidden = !keys.includes(key);
  }
}

/** Copies one step's page copy into the live caption. Returns false when the page has no such step. */
function copyStep(steps: HTMLElement | null, caption: HTMLElement | null, key: string): boolean {
  const source = steps?.querySelector<HTMLElement>(`[data-step="${key}"]`);
  if (!source || !caption) return false;
  caption.replaceChildren(...Array.from(source.childNodes, (node) => node.cloneNode(true)));
  caption.hidden = false;
  return true;
}

export function mountArchFaultMap(root: HTMLElement): void {
  const caption = root.querySelector<HTMLElement>("[data-iso-caption]");
  const steps = root.querySelector<HTMLElement>("[data-iso-steps]");
  const legacyPane = root.querySelector<HTMLElement>("[data-iso-legacy]");
  const legacyCode = root.querySelector<HTMLElement>("[data-iso-lcode]");
  const mingaCode = root.querySelector<HTMLElement>("[data-iso-mcode]");
  const queued = root.querySelector<HTMLElement>("[data-iso-queued]");
  const timer = root.querySelector<HTMLElement>("[data-iso-timer]");
  const buttons = Array.from(root.querySelectorAll<HTMLButtonElement>("[data-iso-fault]"));

  let state = createIsolationSimState();
  let shownView: IsolationView | null = null;
  let tickTimer: number | null = null;
  let typeTimer: number | null = null;

  function stopTimers(): void {
    if (tickTimer !== null) window.clearInterval(tickTimer);
    if (typeTimer !== null) window.clearInterval(typeTimer);
    tickTimer = null;
    typeTimer = null;
  }

  function render(): void {
    const reduced = prefersReducedMotion();

    if (state.view !== shownView) {
      shownView = state.view;
      showOnly(root, "data-iso-show", state.view);
      if (copyStep(steps, caption, state.view)) steps?.classList.add("is-enhanced");
      legacyPane?.classList.toggle("is-broken", state.view === "slow-during" || state.legacyDead);
      legacyPane?.classList.toggle("is-frozen", state.view === "slow-during");
    }

    if (legacyCode) renderElixirLineDom(legacyCode, state.legacyText);
    if (mingaCode) renderElixirLineDom(mingaCode, state.mingaText);
    if (queued) queued.textContent = String(state.legacyQueued);
    if (timer) {
      const counting = !reduced && state.view === "slow-during";
      timer.textContent = counting ? `${(state.remainingMs / 1000).toFixed(1)} s` : "";
    }

    for (const btn of buttons) {
      const kind = btn.getAttribute("data-iso-fault") as FaultKind;
      const label = faultButtonLabel(state, kind, reduced);
      btn.setAttribute("aria-pressed", state.fault === kind && state.remainingMs > 0 ? "true" : "false");
      for (const span of btn.querySelectorAll<HTMLElement>("[data-iso-label]")) {
        span.hidden = span.getAttribute("data-iso-label") !== label;
      }
    }
  }

  function start(kind: FaultKind): void {
    stopTimers();
    state = triggerIsolationFault(kind);

    if (prefersReducedMotion()) {
      state = applyTypedText(state, ISOLATION_TYPED);
      render();
      return;
    }

    render();
    let typed = 0;
    typeTimer = window.setInterval(() => {
      const ch = ISOLATION_TYPED[typed];
      if (ch === undefined) {
        if (typeTimer !== null) window.clearInterval(typeTimer);
        typeTimer = null;
        return;
      }
      typed += 1;
      state = applyTypedChar(state, ch);
      render();
    }, TYPE_INTERVAL_MS);
    tickTimer = window.setInterval(() => {
      state = tickIsolationSim(state, TICK_MS);
      if (state.remainingMs <= 0) stopTimers();
      render();
    }, TICK_MS);
  }

  root.addEventListener("click", (event) => {
    const btn = (event.target as HTMLElement | null)?.closest<HTMLElement>("[data-iso-fault]");
    if (!btn) return;
    const kind = btn.getAttribute("data-iso-fault");
    if (kind !== "slow_server" && kind !== "parser_crash") return;

    if (faultButtonLabel(state, kind, prefersReducedMotion()) === "next") {
      stopTimers();
      state = finishIsolationFault(state);
      render();
      return;
    }
    start(kind);
  });

  render();
}

const ROW_MARK: Readonly<Record<StagedCodeRow["kind"], string>> = { normal: "", add: "+", del: "-", you: "~" };

export function mountStagedStepper(root: HTMLElement): void {
  const caption = root.querySelector<HTMLElement>("[data-st-caption]");
  const steps = root.querySelector<HTMLElement>("[data-st-steps]");
  const rowsEl = root.querySelector<HTMLElement>("[data-st-rows]");
  const count = root.querySelector<HTMLElement>("[data-st-count]");
  const back = root.querySelector<HTMLElement>('[data-st-nav="back"]');

  let state = createStagedPipelineState();

  function renderRows(rows: readonly StagedCodeRow[]): void {
    if (!rowsEl) return;
    const nodes = rows.map((row) => {
      const line = document.createElement("div");
      line.className = `st-row is-${row.kind}`;
      const ln = document.createElement("span");
      ln.className = "st-ln";
      ln.textContent = `${ROW_MARK[row.kind]}${row.ln}`;
      const code = document.createElement("span");
      code.className = "st-code";
      renderElixirLineDom(code, row.code);
      line.append(ln, code);
      return line;
    });
    rowsEl.replaceChildren(...nodes);
  }

  function render(): void {
    const snap = computeStagedSnapshot(state);
    showOnly(root, "data-st-show", snap.view);
    if (copyStep(steps, caption, snap.view)) steps?.classList.add("is-enhanced");
    renderRows(snap.rows);
    if (count) count.textContent = String(state.step);
    back?.setAttribute("aria-disabled", state.step === 1 ? "true" : "false");
    for (const btn of root.querySelectorAll<HTMLElement>("[data-st-conflict-mode]")) {
      const conflict = btn.getAttribute("data-st-conflict-mode") === "conflict";
      btn.setAttribute("aria-pressed", conflict === state.conflictMode ? "true" : "false");
      btn.classList.toggle("is-active", conflict === state.conflictMode);
    }
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;

    const nav = target.closest<HTMLElement>("[data-st-nav]");
    if (nav) {
      state = stepStagedPipeline(state, nav.getAttribute("data-st-nav") === "back" ? "back" : "next");
      render();
      return;
    }

    const mode = target.closest<HTMLElement>("[data-st-conflict-mode]");
    if (mode) {
      state = { ...state, conflictMode: mode.getAttribute("data-st-conflict-mode") === "conflict" };
      render();
    }
  });

  render();
}
