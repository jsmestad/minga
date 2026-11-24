/* Architecture interactive demos:
   1. Live side-by-side typing fault simulator (Single-Loop Editor vs Minga BEAM Isolation).
   2. Airy, syntax-highlighted 4-step Staged Overlay & 3-Way Merge visualizer. */

import { highlightElixirLine, renderElixirLineDom } from "./highlight.ts";

export type FaultKind = "none" | "lsp_hang" | "parser_crash" | "hook_error";

export interface IsolationSimState {
  readonly fault: FaultKind;
  readonly remainingMs: number;
  readonly mingaText: string;
  readonly legacyText: string;
  readonly legacyQueued: string;
  readonly legacyDead: boolean;
  readonly mingaParserPlain: boolean;
  readonly notice: string;
}

const DEFAULT_LINE = 'def retry_after(429), do: {:backoff, 250}';

export function createIsolationSimState(): IsolationSimState {
  return {
    fault: "none",
    remainingMs: 0,
    mingaText: DEFAULT_LINE,
    legacyText: DEFAULT_LINE,
    legacyQueued: "",
    legacyDead: false,
    mingaParserPlain: false,
    notice: "Type below or click a fault trigger to feel how BEAM isolation protects keystrokes.",
  };
}

export function triggerIsolationFault(state: IsolationSimState, fault: FaultKind): IsolationSimState {
  if (fault === "none") {
    return createIsolationSimState();
  }
  if (fault === "lsp_hang") {
    return {
      ...state,
      fault: "lsp_hang",
      remainingMs: 3000,
      legacyDead: false,
      mingaParserPlain: false,
      notice: "ElixirLS blocked for 3.0s. Keep typing: the single-loop editor freezes while Minga stays instant.",
    };
  }
  if (fault === "parser_crash") {
    return {
      ...state,
      fault: "parser_crash",
      remainingMs: 700,
      legacyDead: true,
      legacyQueued: "",
      mingaParserPlain: true,
      notice: "Malformed grammar segfaulted the C parser. In-process editor crashed; Minga respawned its Zig port in 14ms with 0 text lost.",
    };
  }
  return {
    ...state,
    fault: "hook_error",
    remainingMs: 2200,
    legacyDead: false,
    mingaParserPlain: false,
    notice: "User :after_save hook raised MatchError. Single-loop save aborted; Minga contained the exception in a background Task.",
  };
}

export function applyTypedChar(state: IsolationSimState, nextText: string): IsolationSimState {
  const mingaText = nextText;
  if (state.legacyDead) {
    return { ...state, mingaText };
  }
  if (state.fault === "lsp_hang" && state.remainingMs > 0) {
    const added = nextText.length >= state.mingaText.length ? nextText.slice(state.mingaText.length) : "⌫";
    return {
      ...state,
      mingaText,
      legacyQueued: state.legacyQueued + added,
    };
  }
  return {
    ...state,
    mingaText,
    legacyText: nextText,
  };
}

export function tickIsolationSim(state: IsolationSimState, deltaMs: number): IsolationSimState {
  if (state.remainingMs <= 0) return state;
  const nextRem = Math.max(0, state.remainingMs - deltaMs);
  if (nextRem > 0) {
    return { ...state, remainingMs: nextRem };
  }
  if (state.fault === "lsp_hang") {
    return {
      ...state,
      fault: "none",
      remainingMs: 0,
      legacyText: state.mingaText,
      legacyQueued: "",
      notice: "LSP unblocked after 3.0s. Single-loop editor finally flushed its stalled keystrokes; Minga never missed a frame.",
    };
  }
  if (state.fault === "parser_crash") {
    return {
      ...state,
      remainingMs: 0,
      mingaParserPlain: false,
      notice: "Minga's Zig parser port respawned cleanly and restored syntax highlighting; the in-process editor is still dead until restart.",
    };
  }
  return {
    ...state,
    fault: "none",
    remainingMs: 0,
    notice: "Hook error cleared. Minga saved cleanly without blocking typing.",
  };
}

export type StagedStep = 1 | 2 | 3 | 4;

export interface StagedPipelineState {
  readonly step: StagedStep;
  readonly conflictMode: boolean;
}

export interface StagedCodeRow {
  readonly ln: string;
  readonly kind: "normal" | "add" | "you" | "conflict";
  readonly code: string;
}

export interface StagedViewSnapshot {
  readonly title: string;
  readonly summary: string;
  readonly editorHeader: string;
  readonly rows: readonly StagedCodeRow[];
  readonly diskStatus: { readonly label: string; readonly tone: "ok" | "warn" };
  readonly bufferStatus: { readonly label: string; readonly tone: "ok" | "warn" };
  readonly overlayStatus: { readonly label: string; readonly tone: "ok" | "warn" | "fail" };
}

export function createStagedPipelineState(): StagedPipelineState {
  return { step: 1, conflictMode: false };
}

export function computeStagedSnapshot(state: StagedPipelineState): StagedViewSnapshot {
  if (state.step === 1) {
    return {
      title: "1. Revision check before any edit",
      summary: "The agent reads retry.ex at rev 42 and attaches that token to its edit call. Stale proposals reject before touching a byte.",
      editorHeader: "retry.ex · rev 42 (read verified)",
      rows: [
        { ln: "238", kind: "normal", code: "def classify(status) do" },
        { ln: "239", kind: "normal", code: "  if status >= 500, do: :retry, else: :fatal" },
        { ln: "240", kind: "normal", code: "end" },
        { ln: "241", kind: "normal", code: "def timeout_ms, do: 5_000" },
      ],
      diskStatus: { label: "Clean (0 modified)", tone: "ok" },
      bufferStatus: { label: "rev 42 · untouched", tone: "ok" },
      overlayStatus: { label: "Token rev 42 matched", tone: "ok" },
    };
  }

  if (state.step === 2) {
    return {
      title: "2. Agent stages off disk in an isolated overlay",
      summary: "Approved agent edits land in memory + ~/.local/share/minga/staged_drafts. Your Git working tree stays completely clean.",
      editorHeader: "Staged overlay fork · base rev 42",
      rows: [
        { ln: "238", kind: "normal", code: "def classify(status) do" },
        { ln: "+239", kind: "add", code: "  case status do" },
        { ln: "+240", kind: "add", code: "    429 -> :rate_limited" },
        { ln: "+241", kind: "add", code: "    code when code >= 500 -> :retry" },
        { ln: "242", kind: "normal", code: "  end" },
        { ln: "243", kind: "normal", code: "def timeout_ms, do: 5_000" },
      ],
      diskStatus: { label: "Clean (untouched)", tone: "ok" },
      bufferStatus: { label: "rev 42 · cursor free", tone: "ok" },
      overlayStatus: { label: "+3 staged · draft saved", tone: "warn" },
    };
  }

  if (state.step === 3) {
    const rows: readonly StagedCodeRow[] = state.conflictMode
      ? [
          { ln: "238", kind: "normal", code: "def classify(status) do" },
          { ln: "239", kind: "you", code: "  if status >= 500, do: :backoff, else: :fatal  # your edit" },
          { ln: "240", kind: "normal", code: "end" },
          { ln: "241", kind: "normal", code: "def timeout_ms, do: 5_000" },
        ]
      : [
          { ln: "238", kind: "normal", code: "def classify(status) do" },
          { ln: "239", kind: "normal", code: "  if status >= 500, do: :retry, else: :fatal" },
          { ln: "240", kind: "normal", code: "end" },
          { ln: "241", kind: "you", code: "def timeout_ms, do: 15_000  # your concurrent edit" },
        ];
    return {
      title: state.conflictMode ? "3. You edit the same line (line 239)" : "3. You keep editing another line (line 241)",
      summary: state.conflictMode
        ? "Your open buffer moves to rev 43 on line 239 while the agent's overlay stays safely isolated at base rev 42."
        : "Your open buffer advances to rev 43 on line 241. The overlay stays separate and survives editor restarts.",
      editorHeader: "Your open buffer · rev 43 (overlay isolated)",
      rows,
      diskStatus: { label: "Clean (untouched)", tone: "ok" },
      bufferStatus: { label: "rev 43 · your edit live", tone: "ok" },
      overlayStatus: { label: state.conflictMode ? "Overlaps line 239" : "Persisted · ready", tone: state.conflictMode ? "fail" : "warn" },
    };
  }

  if (state.conflictMode) {
    return {
      title: "4. Publish pauses for safe conflict review",
      summary: "Both you and the agent edited line 239. 3-way merge refuses to overwrite your edit and opens explicit conflict review.",
      editorHeader: "Conflict review · line 239 protected",
      rows: [
        { ln: "238", kind: "normal", code: "def classify(status) do" },
        { ln: "<<<", kind: "conflict", code: "<<<<<<< your buffer (rev 43)" },
        { ln: "239", kind: "you", code: "  if status >= 500, do: :backoff, else: :fatal" },
        { ln: "===", kind: "conflict", code: "=======" },
        { ln: "+239", kind: "add", code: "  case status do 429 -> :rate_limited; _ -> :retry end" },
        { ln: ">>>", kind: "conflict", code: ">>>>>>> agent overlay (base rev 42)" },
      ],
      diskStatus: { label: "Clean (publish paused)", tone: "ok" },
      bufferStatus: { label: "rev 43 · never clobbered", tone: "ok" },
      overlayStatus: { label: "Conflict review open", tone: "fail" },
    };
  }

  return {
    title: "4. Clean 3-way merge via SPC a p",
    summary: "Non-overlapping edits merge cleanly into your buffer and disk in one undoable step, keeping your line 243 edit intact.",
    editorHeader: "retry.ex · rev 44 (published cleanly)",
    rows: [
      { ln: "238", kind: "normal", code: "def classify(status) do" },
      { ln: "239", kind: "add", code: "  case status do" },
      { ln: "240", kind: "add", code: "    429 -> :rate_limited" },
      { ln: "241", kind: "add", code: "    code when code >= 500 -> :retry" },
      { ln: "242", kind: "normal", code: "  end" },
      { ln: "243", kind: "you", code: "def timeout_ms, do: 15_000  # preserved!" },
    ],
    diskStatus: { label: "Modified retry.ex", tone: "warn" },
    bufferStatus: { label: "rev 44 · 1 undo step", tone: "ok" },
    overlayStatus: { label: "Cleared cleanly", tone: "ok" },
  };
}

function esc(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function mountArchFaultMap(root: HTMLElement): void {
  let state = createIsolationSimState();
  let tickTimer: number | null = null;
  let autoTypeTimer: number | null = null;

  function stopTimers(): void {
    if (tickTimer !== null) {
      window.clearInterval(tickTimer);
      tickTimer = null;
    }
    if (autoTypeTimer !== null) {
      window.clearInterval(autoTypeTimer);
      autoTypeTimer = null;
    }
  }

  function startAutoTypeBurst(): void {
    if (autoTypeTimer !== null) {
      window.clearInterval(autoTypeTimer);
      autoTypeTimer = null;
    }
    const phrase = " # fast!";
    let idx = 0;
    autoTypeTimer = window.setInterval(() => {
      if (idx >= phrase.length) {
        if (autoTypeTimer !== null) window.clearInterval(autoTypeTimer);
        autoTypeTimer = null;
        return;
      }
      state = applyTypedChar(state, state.mingaText + phrase[idx]!);
      idx += 1;
      syncLivePanels();
    }, 190);
  }

  function startFault(kind: FaultKind): void {
    stopTimers();
    state = triggerIsolationFault(state, kind);
    renderFull();
    if (kind === "none") return;

    if (kind === "lsp_hang") {
      startAutoTypeBurst();
    }

    tickTimer = window.setInterval(() => {
      state = tickIsolationSim(state, 100);
      syncLivePanels();
      if (state.remainingMs <= 0 && tickTimer !== null) {
        window.clearInterval(tickTimer);
        tickTimer = null;
      }
    }, 100);
  }

  function syncLivePanels(): void {
    const input = root.querySelector<HTMLInputElement>("[data-iso-input]");
    if (input && document.activeElement !== input) {
      input.value = state.mingaText;
    }

    const legacyPane = root.querySelector<HTMLElement>("[data-iso-legacy]");
    const mingaPane = root.querySelector<HTMLElement>("[data-iso-minga]");
    const noticeEl = root.querySelector<HTMLElement>("[data-iso-notice]");

    if (noticeEl) noticeEl.textContent = state.notice;

    const secs = (state.remainingMs / 1000).toFixed(1);
    const frozen = state.fault === "lsp_hang" && state.remainingMs > 0;
    const hookErr = state.fault === "hook_error" && state.remainingMs > 0;

    if (legacyPane) {
      let badgeText = "0.6ms · Ready";
      let badgeCls = "is-ok";
      let foot = "Shared main loop: editor, plugins, and LSP share one thread.";
      let stallText = "";

      if (state.legacyDead) {
        badgeText = "CRASHED · SIGSEGV";
        badgeCls = "is-fail";
        foot = "In-process C parser took down the entire editor process.";
      } else if (frozen) {
        badgeText = `FROZEN · ${secs}s LEFT`;
        badgeCls = "is-fail";
        stallText = `UI thread blocked · ${state.legacyQueued.length} keystroke${state.legacyQueued.length === 1 ? "" : "s"} stalled in queue...`;
        foot = "Cursor stopped responding until LSP finishes blocking.";
      } else if (hookErr) {
        badgeText = "SAVE ABORTED";
        badgeCls = "is-fail";
        stallText = "Unhandled MatchError in :after_save interrupted buffer save.";
        foot = "Uncaught hook exception surfaced directly on the editor loop.";
      }

      legacyPane.className = `iso-editor ${state.legacyDead || frozen || hookErr ? "is-broken" : ""}`;
      legacyPane.innerHTML = `
        <div class="iso-ed-head"><strong>Single-Loop Editor</strong><span class="topo-pill ${badgeCls}" data-iso-lbadge></span></div>
        <div class="iso-ed-body" data-iso-lbody></div>
        <div class="iso-ed-foot" data-iso-lfoot></div>
      `;
      const lBadge = legacyPane.querySelector<HTMLElement>("[data-iso-lbadge]");
      const lBody = legacyPane.querySelector<HTMLElement>("[data-iso-lbody]");
      const lFoot = legacyPane.querySelector<HTMLElement>("[data-iso-lfoot]");
      if (lBadge) lBadge.textContent = badgeText;
      if (lFoot) lFoot.textContent = foot;
      if (lBody) {
        if (state.legacyDead) {
          const deadEl = document.createElement("div");
          deadEl.className = "iso-dead";
          deadEl.textContent = "Process terminated (signal 11). Unsaved buffer changes lost.";
          lBody.appendChild(deadEl);
        } else {
          const codeEl = document.createElement("div");
          codeEl.className = frozen ? "iso-code-line is-frozen" : "iso-code-line";
          renderElixirLineDom(codeEl, state.legacyText);
          if (!frozen) {
            const caret = document.createElement("span");
            caret.className = "iso-caret";
            codeEl.appendChild(caret);
          }
          lBody.appendChild(codeEl);
          if (stallText) {
            const stallEl = document.createElement("div");
            stallEl.className = "iso-stall";
            stallEl.textContent = stallText;
            lBody.appendChild(stallEl);
          }
        }
      }
    }

    if (mingaPane) {
      let badgeText = "0.4ms · INSTANT";
      let badgeCls = "is-ok";
      let sideStatus = "All BEAM supervisors healthy";
      if (frozen) {
        sideStatus = `ElixirLS reindexing in separate process (${secs}s) · typing unaffected`;
      } else if (state.mingaParserPlain) {
        badgeText = "RESPAWNING ZIG PORT";
        badgeCls = "is-warn";
        sideStatus = "Highlighting paused for 14ms while Zig port respawns · buffer 100% intact";
      } else if (state.fault === "parser_crash" && !state.mingaParserPlain) {
        badgeText = "PORT RESPAWNED (14ms)";
        sideStatus = "Syntax colors restored automatically · 0 characters lost";
      } else if (hookErr) {
        badgeText = "SAVED ✓ · TASK ISOLATED";
        sideStatus = "Hook MatchError caught in async BEAM Task · typing unaffected";
      }

      mingaPane.innerHTML = `
        <div class="iso-ed-head"><strong>Minga (BEAM Isolated)</strong><span class="topo-pill ${badgeCls}" data-iso-mbadge></span></div>
        <div class="iso-ed-body" data-iso-mbody></div>
        <div class="iso-ed-foot" data-iso-mfoot></div>
      `;
      const mBadge = mingaPane.querySelector<HTMLElement>("[data-iso-mbadge]");
      const mBody = mingaPane.querySelector<HTMLElement>("[data-iso-mbody]");
      const mFoot = mingaPane.querySelector<HTMLElement>("[data-iso-mfoot]");
      if (mBadge) mBadge.textContent = badgeText;
      if (mFoot) mFoot.textContent = sideStatus;
      if (mBody) {
        const codeEl = document.createElement("div");
        codeEl.className = "iso-code-line";
        renderElixirLineDom(codeEl, state.mingaText, state.mingaParserPlain);
        const caret = document.createElement("span");
        caret.className = "iso-caret is-alive";
        codeEl.appendChild(caret);
        mBody.appendChild(codeEl);
      }
    }
  }

  function renderFull(): void {
    root.innerHTML = `
      <div class="story-box iso-box">
        <div class="story-bar">
          <span>LIVE ISOLATION DEMO · FIRE A FAULT &amp; TYPE BELOW</span>
          <div class="seg-group" role="group" aria-label="Inject real-time faults">
            <button type="button" class="seg-btn ${state.fault === "lsp_hang" ? "is-active" : ""}" data-iso-fault="lsp_hang">Hang LSP (3s)</button>
            <button type="button" class="seg-btn ${state.fault === "parser_crash" ? "is-active" : ""}" data-iso-fault="parser_crash">Crash Parser</button>
            <button type="button" class="seg-btn ${state.fault === "hook_error" ? "is-active" : ""}" data-iso-fault="hook_error">Crash :after_save</button>
            <button type="button" class="seg-btn" data-iso-fault="none">Reset</button>
          </div>
        </div>
        <div class="iso-input-bar">
          <label for="iso-live-input">Type here while faults run:</label>
          <input id="iso-live-input" class="iso-input" type="text" data-iso-input spellcheck="false" autocomplete="off">
        </div>
        <div class="iso-compare">
          <div class="iso-editor" data-iso-legacy></div>
          <div class="iso-editor is-minga" data-iso-minga></div>
        </div>
        <div class="iso-notice" data-iso-notice aria-live="polite"></div>
      </div>
    `;
    syncLivePanels();
  }

  root.addEventListener("click", (event) => {
    const btn = (event.target as HTMLElement | null)?.closest<HTMLElement>("[data-iso-fault]");
    if (!btn) return;
    const f = btn.getAttribute("data-iso-fault") as FaultKind | null;
    if (f === "none" || f === "lsp_hang" || f === "parser_crash" || f === "hook_error") {
      startFault(f);
    }
  });

  root.addEventListener("input", (event) => {
    const target = event.target as HTMLInputElement | null;
    if (target?.matches("[data-iso-input]")) {
      state = applyTypedChar(state, target.value);
      syncLivePanels();
    }
  });

  renderFull();
}

export function mountStagedStepper(root: HTMLElement): void {
  let state = createStagedPipelineState();

  function render(): void {
    const snap = computeStagedSnapshot(state);
    const steps: readonly { readonly n: StagedStep; readonly label: string }[] = [
      { n: 1, label: "1. Revision check" },
      { n: 2, label: "2. Stage off disk" },
      { n: 3, label: "3. Your edit" },
      { n: 4, label: "4. Publish (SPC a p)" },
    ];

    const stepBtns = steps
      .map(
        (s) =>
          `<button type="button" class="seg-btn ${state.step === s.n ? "is-active" : ""}" data-st-step="${s.n}">${s.label}</button>`,
      )
      .join("");

    const codeRows = snap.rows
      .map((r) => {
        const html = r.kind === "conflict" ? `<span class="st-cmark">${esc(r.code)}</span>` : highlightElixirLine(r.code);
        return `<div class="st-row is-${r.kind}"><span class="st-ln">${esc(r.ln)}</span><span class="st-code">${html}</span></div>`;
      })
      .join("");

    root.innerHTML = `
      <div class="story-box">
        <div class="story-bar">
          <span>STAGED OVERLAY PIPELINE</span>
          <div class="seg-group" role="group" aria-label="Merge scenario">
            <button type="button" class="seg-btn ${!state.conflictMode ? "is-active" : ""}" data-st-conflict-mode="clean">Clean 3-way merge</button>
            <button type="button" class="seg-btn ${state.conflictMode ? "is-active" : ""}" data-st-conflict-mode="conflict">Same-line conflict</button>
          </div>
        </div>
        <div class="st-step-row" role="group" aria-label="Staged overlay steps">${stepBtns}</div>
        <div class="st-clean-layout">
          <div class="st-editor">
            <div class="st-ed-bar"><span>${esc(snap.editorHeader)}</span><span>Elixir</span></div>
            <div class="st-ed-body">${codeRows}</div>
          </div>
          <div class="st-ledger">
            <div class="st-stat">
              <span class="lens-k">GIT ON DISK</span>
              <span class="topo-pill is-${snap.diskStatus.tone}">${esc(snap.diskStatus.label)}</span>
            </div>
            <div class="st-stat">
              <span class="lens-k">OPEN BUFFER</span>
              <span class="topo-pill is-${snap.bufferStatus.tone}">${esc(snap.bufferStatus.label)}</span>
            </div>
            <div class="st-stat">
              <span class="lens-k">STAGED OVERLAY</span>
              <span class="topo-pill is-${snap.overlayStatus.tone}">${esc(snap.overlayStatus.label)}</span>
            </div>
          </div>
        </div>
        <div class="st-foot"><strong>${esc(snap.title)}:</strong> ${esc(snap.summary)}</div>
      </div>
    `;
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;

    const stepBtn = target.closest<HTMLElement>("[data-st-step]");
    if (stepBtn) {
      const n = Number(stepBtn.getAttribute("data-st-step"));
      if (n === 1 || n === 2 || n === 3 || n === 4) {
        state = { ...state, step: n };
        render();
      }
      return;
    }

    const modeBtn = target.closest<HTMLElement>("[data-st-conflict-mode]");
    if (modeBtn) {
      const m = modeBtn.getAttribute("data-st-conflict-mode");
      state = { ...state, conflictMode: m === "conflict" };
      render();
    }
  });

  render();
}
