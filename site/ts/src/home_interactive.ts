/* Homepage interactive enhancements: playable 4-tab Feature Tour + live Semantic Theme Role Switcher. */

export type TourTwistStatus = "unreviewed" | "kept" | "rejected";
export type TourApprovalState = "needs_you" | "approved_once" | "approved_session" | "approved_turn" | "denied";
export type TourParityView = "split" | "macos" | "tui_truecolor" | "tui_16";
export type TourOrbitState = "working" | "needs_you" | "failed" | "done";
export type MarksThemeId = "catppuccin_frappe" | "catppuccin_latte" | "astrodark" | "doom_one";

export interface HeroTourState {
  readonly userEditPresent: boolean;
  readonly twistStatus: TourTwistStatus;
  readonly twistEcho: string;
  readonly peekIndex: number;
  readonly peekBriefOpen: boolean;
  readonly parentDraft: string;
  readonly approvalState: TourApprovalState;
  readonly showTaskDiff: boolean;
  readonly queueItems: readonly string[];
  readonly parityView: TourParityView;
  readonly parityOrbit: TourOrbitState;
}

export interface PeekWorkerSpec {
  readonly name: string;
  readonly state: "working" | "needs_you" | "done";
  readonly glyph: string;
  readonly roleClass: string;
  readonly brief: string;
  readonly lines: readonly { readonly glyph: string; readonly cls: string; readonly text: string }[];
}

export const HERO_PEEK_WORKERS: readonly PeekWorkerSpec[] = [
  {
    name: "Edge-Case Tester",
    state: "done",
    glyph: "●",
    roleClass: "ml-done",
    brief: "Audit 429, 529, and 5xx retry branches in lib/minga_agent/retry.ex and list missing clauses.",
    lines: [
      { glyph: "●", cls: "ml-done", text: "Found missing HTTP 529 overloaded clause in classify_status/2" },
      { glyph: "●", cls: "ml-done", text: "Verified Retry-After delta-seconds bounds and reported back to parent" },
    ],
  },
  {
    name: "Fact-Check Auditor",
    state: "working",
    glyph: "◐",
    roleClass: "ml-minga",
    brief: "Verify RFC 9110 Retry-After parsing and backoff cap constants against test fixtures.",
    lines: [
      { glyph: "●", cls: "ml-done", text: "Checked HTTP 429 Retry-After parsing against RFC 9110" },
      { glyph: "◐", cls: "ml-minga", text: "Cross-checking backoff cap in lib/minga_agent/retry.ex" },
    ],
  },
  {
    name: "Usage-Limit Tests",
    state: "needs_you",
    glyph: "◉",
    roleClass: "ml-needs",
    brief: "Write isolated unit tests for 429/529 retry backoff and verify zero flaky timers.",
    lines: [
      { glyph: "◉", cls: "ml-needs", text: "Waiting on approval to create test/minga_agent/usage_limit_test.exs (+86)" },
      { glyph: "●", cls: "ml-done", text: "Mock clock fixture ready; 0 sleep calls" },
    ],
  },
  {
    name: "Docs Sync",
    state: "working",
    glyph: "◐",
    roleClass: "ml-minga",
    brief: "Check whether public return tuples changed in docs/ and update examples if needed.",
    lines: [
      { glyph: "●", cls: "ml-done", text: "Confirmed {:rate_limited, ms} and {:overloaded, ms} match spec" },
      { glyph: "◐", cls: "ml-minga", text: "Scanning docs/agent.md for retry table mentions" },
    ],
  },
];

export interface SemanticThemeRoles {
  readonly label: string;
  readonly isLight: boolean;
  readonly bg: string;
  readonly border: string;
  readonly text: string;
  readonly minga: string;
  readonly mingaDim: string;
  readonly you: string;
  readonly needsYou: string;
  readonly waiting: string;
  readonly failure: string;
  readonly done: string;
}

export const SEMANTIC_MARK_THEMES: Record<MarksThemeId, SemanticThemeRoles> = {
  catppuccin_frappe: {
    label: "Catppuccin Frappé",
    isLight: false,
    bg: "#303446",
    border: "#414559",
    text: "#c6d0f5",
    minga: "#ca9ee6",
    mingaDim: "#74628d",
    you: "#8caaee",
    needsYou: "#ef9f76",
    waiting: "#838ba7",
    failure: "#e78284",
    done: "#a6d189",
  },
  catppuccin_latte: {
    label: "Catppuccin Latte",
    isLight: true,
    bg: "#eff1f5",
    border: "#ccd0da",
    text: "#4c4f69",
    minga: "#8839ef",
    mingaDim: "#b896e8",
    you: "#1e66f5",
    needsYou: "#fe640b",
    waiting: "#7c7f93",
    failure: "#d20f39",
    done: "#40a02b",
  },
  astrodark: {
    label: "AstroDark",
    isLight: false,
    bg: "#1a1d23",
    border: "#2a2f3a",
    text: "#d8dee9",
    minga: "#c678dd",
    mingaDim: "#6f497c",
    you: "#61afef",
    needsYou: "#d19a66",
    waiting: "#7b8496",
    failure: "#e06c75",
    done: "#98c379",
  },
  doom_one: {
    label: "Doom One",
    isLight: false,
    bg: "#282c34",
    border: "#3f444a",
    text: "#bbc2cf",
    minga: "#c678dd",
    mingaDim: "#725180",
    you: "#51afef",
    needsYou: "#da8548",
    waiting: "#6d7580",
    failure: "#ff6c6b",
    done: "#98be65",
  },
};

export function createHeroTourState(): HeroTourState {
  return {
    userEditPresent: true,
    twistStatus: "unreviewed",
    twistEcho: "Line 240 has a shared blue+mauve strand. Press u Undo yours to revert only your line.",
    peekIndex: 1,
    peekBriefOpen: false,
    parentDraft: "Also verify Retry-After HTTP-date headers before merge...",
    approvalState: "needs_you",
    showTaskDiff: false,
    queueItems: [
      "Run mix test test/minga_agent/retry_test.exs after edit",
      "Summarize changed error tuples for the PR description",
    ],
    parityView: "split",
    parityOrbit: "working",
  };
}

export type HeroTourAction =
  | { readonly type: "undo_yours" }
  | { readonly type: "toggle_edit" }
  | { readonly type: "keep_twist" }
  | { readonly type: "reject_twist" }
  | { readonly type: "reset_twist" }
  | { readonly type: "peek_select"; readonly index: number }
  | { readonly type: "peek_step"; readonly delta: -1 | 1 }
  | { readonly type: "peek_toggle_brief" }
  | { readonly type: "set_draft"; readonly text: string }
  | { readonly type: "approve"; readonly choice: "y" | "a" | "t" | "n" | "reset" }
  | { readonly type: "toggle_diff" }
  | { readonly type: "queue_drop_top" }
  | { readonly type: "queue_swap" }
  | { readonly type: "queue_add" }
  | { readonly type: "set_parity_view"; readonly view: TourParityView }
  | { readonly type: "set_parity_orbit"; readonly orbit: TourOrbitState };

export function reduceHeroTour(state: HeroTourState, action: HeroTourAction): HeroTourState {
  switch (action.type) {
    case "undo_yours":
      if (!state.userEditPresent) {
        return { ...state, twistEcho: "Your undo stack is clean. Minga's 4 braided lines remain untouched." };
      }
      return {
        ...state,
        userEditPresent: false,
        twistEcho: "u undid only your edit on line 240; Minga's braided change stayed intact.",
      };
    case "toggle_edit":
      return {
        ...state,
        userEditPresent: true,
        twistStatus: state.twistStatus === "rejected" ? "unreviewed" : state.twistStatus,
        twistEcho: "Edited line 240 inside Minga's change: one strand turned blue for shared authorship.",
      };
    case "keep_twist":
      return {
        ...state,
        twistStatus: "kept",
        twistEcho: "SPC a y kept Minga's 4 lines. The braid flattened to a muted accepted strand until commit.",
      };
    case "reject_twist":
      return {
        ...state,
        twistStatus: "rejected",
        userEditPresent: false,
        twistEcho: "SPC a d rejected Minga's change cleanly and restored the original line.",
      };
    case "reset_twist":
      return {
        ...state,
        userEditPresent: true,
        twistStatus: "unreviewed",
        twistEcho: "Reset specimen: braided Twist on lines 238–241 with your edit on line 240.",
      };
    case "peek_select": {
      const clamped = Math.max(0, Math.min(HERO_PEEK_WORKERS.length - 1, action.index));
      return { ...state, peekIndex: clamped };
    }
    case "peek_step": {
      const len = HERO_PEEK_WORKERS.length;
      const next = (state.peekIndex + action.delta + len) % len;
      return { ...state, peekIndex: next };
    }
    case "peek_toggle_brief":
      return { ...state, peekBriefOpen: !state.peekBriefOpen };
    case "set_draft":
      return { ...state, parentDraft: action.text };
    case "approve": {
      const map: Record<"y" | "a" | "t" | "n" | "reset", TourApprovalState> = {
        y: "approved_once",
        a: "approved_session",
        t: "approved_turn",
        n: "denied",
        reset: "needs_you",
      };
      return { ...state, approvalState: map[action.choice] };
    }
    case "toggle_diff":
      return { ...state, showTaskDiff: !state.showTaskDiff };
    case "queue_drop_top":
      if (state.queueItems.length === 0) return state;
      return { ...state, queueItems: state.queueItems.slice(1) };
    case "queue_swap":
      if (state.queueItems.length < 2) return state;
      return { ...state, queueItems: [state.queueItems[1]!, state.queueItems[0]!, ...state.queueItems.slice(2)] };
    case "queue_add": {
      if (state.queueItems.length >= 4) return state;
      const extras = [
        "Verify dialyzer passes with zero warnings",
        "Check Retry-After HTTP-date header edge case",
      ];
      const nextItem = extras[state.queueItems.length % extras.length]!;
      return { ...state, queueItems: [...state.queueItems, nextItem] };
    }
    case "set_parity_view":
      return { ...state, parityView: action.view };
    case "set_parity_orbit":
      return { ...state, parityOrbit: action.orbit };
  }
}

function esc(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function twistCrossSvg(minga: string, dim: string, bg: string): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M7 5 C7 11, 3 11, 3 17 L3 26" fill="none" stroke="${dim}" stroke-width="2.6" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 26" fill="none" stroke="${bg}" stroke-width="5" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 26" fill="none" stroke="${minga}" stroke-width="2.6" stroke-linecap="round"/></svg>`;
}

function twistPairSvg(left: string, right: string, capBottom = false): string {
  const y2 = capBottom ? 19 : 26;
  const cap = capBottom ? ' stroke-linecap="round"' : "";
  return `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M3 0 L3 ${y2}" stroke="${left}" stroke-width="2.6"${cap}/><path d="M7 0 L7 ${y2}" stroke="${right}" stroke-width="2.6"${cap}/></svg>`;
}

function twistSingleSvg(color: string, opacity = 1, width = 1.6): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M5 0 L5 26" stroke="${color}" stroke-opacity="${opacity}" stroke-width="${width}"/></svg>`;
}

export function mountHeroTour(root: HTMLElement): void {
  let state = createHeroTourState();

  const twistPanel = root.querySelector<HTMLElement>("#panel-spec-twist");
  const peekPanel = root.querySelector<HTMLElement>("#panel-spec-peek");
  const tasksPanel = root.querySelector<HTMLElement>("#panel-spec-tasks");
  const parityPanel = root.querySelector<HTMLElement>("#panel-spec-parity");

  function renderTwist(): void {
    if (!twistPanel) return;
    const specimen = twistPanel.querySelector<HTMLElement>(".spine-specimen");
    if (!specimen) return;
    const p = SEMANTIC_MARK_THEMES.catppuccin_frappe;
    const hl = state.twistStatus === "unreviewed" ? "spine-line-hl" : "";
    const isKept = state.twistStatus === "kept";
    const isRejected = state.twistStatus === "rejected";

    const g238 = isRejected ? "" : isKept ? twistSingleSvg(p.minga, 0.48) : twistCrossSvg(p.minga, p.mingaDim, p.bg);
    const g239 = isRejected ? "" : isKept ? twistSingleSvg(p.minga, 0.48) : twistPairSvg(p.mingaDim, p.minga);
    const g240 = isRejected
      ? ""
      : isKept
        ? twistSingleSvg(state.userEditPresent ? p.you : p.minga, state.userEditPresent ? 1 : 0.48)
        : twistPairSvg(state.userEditPresent ? p.you : p.mingaDim, p.minga);
    const g241 = isRejected ? "" : isKept ? twistSingleSvg(p.minga, 0.48) : twistPairSvg(p.mingaDim, p.minga, true);

    const line240 = state.userEditPresent
      ? `    <span class="cnum">529</span> -&gt; {<span class="cat">:overloaded</span>, backoff_ms(<span class="cnum">2</span>)} <span class="ccm"># your edit inside Minga's change</span>`
      : `    <span class="cnum">529</span> -&gt; {<span class="cat">:overloaded</span>, backoff_ms(<span class="cnum">1</span>)}`;

    const bodyRows = isRejected
      ? `<div class="spine-line"><span class="spine-ln">237</span><span class="spine-sign"></span><span class="spine-gutter"></span><span class="spine-code"><span class="ckw">def</span> classify_status(status, _headers) <span class="ckw">do</span></span></div>
         <div class="spine-line"><span class="spine-ln">238</span><span class="spine-sign"></span><span class="spine-gutter"></span><span class="spine-code">  <span class="ckw">if</span> status &gt;= <span class="cnum">500</span>, <span class="ckw">do:</span> {<span class="cat">:retryable</span>, <span class="cnum">250</span>}, <span class="ckw">else:</span> {<span class="cat">:fatal</span>, status}</span></div>
         <div class="spine-line"><span class="spine-ln">239</span><span class="spine-sign"></span><span class="spine-gutter"></span><span class="spine-code"><span class="ckw">end</span></span></div>`
      : `<div class="spine-line"><span class="spine-ln">237</span><span class="spine-sign"></span><span class="spine-gutter"></span><span class="spine-code"><span class="ckw">def</span> classify_status(status, headers) <span class="ckw">do</span></span></div>
         <div class="spine-line ${hl}"><span class="spine-ln">238</span><span class="spine-sign"></span><span class="spine-gutter">${g238}</span><span class="spine-code">  <span class="ckw">case</span> status <span class="ckw">do</span></span></div>
         <div class="spine-line ${hl}"><span class="spine-ln">239</span><span class="spine-sign"></span><span class="spine-gutter">${g239}</span><span class="spine-code">    <span class="cnum">429</span> -&gt; {<span class="cat">:rate_limited</span>, parse_retry_after(headers)}</span></div>
         <div class="spine-line ${hl}"><span class="spine-ln">240</span><span class="spine-sign"></span><span class="spine-gutter">${g240}</span><span class="spine-code">${line240}</span></div>
         <div class="spine-line ${hl}"><span class="spine-ln">241</span><span class="spine-sign"></span><span class="spine-gutter">${g241}</span><span class="spine-code">    code <span class="ckw">when</span> code &gt;= <span class="cnum">500</span> -&gt; {<span class="cat">:retryable</span>, backoff_ms(<span class="cnum">1</span>)}</span></div>
         <div class="spine-line"><span class="spine-ln">242</span><span class="spine-sign"></span><span class="spine-gutter">${twistSingleSvg(p.you, 1, 1.6)}</span><span class="spine-code">    _ -&gt; {<span class="cat">:fatal</span>, status}</span></div>
         <div class="spine-line"><span class="spine-ln">243</span><span class="spine-sign"></span><span class="spine-gutter"></span><span class="spine-code"><span class="ckw">  end</span></span></div>`;

    const mlChange =
      state.twistStatus === "unreviewed"
        ? '<span class="ml-minga">change 1/2</span>'
        : state.twistStatus === "kept"
          ? '<span class="ml-done">● kept</span>'
          : '<span class="ml-dim">rejected</span>';

    specimen.innerHTML = `
      <div class="tour-live-bar">
        <span class="tour-live-label">TRY IT LIVE</span>
        <div class="tour-live-actions">
          <button type="button" class="tour-chip" data-ht-act="undo_yours"><span>u</span> Undo yours</button>
          <button type="button" class="tour-chip" data-ht-act="toggle_edit"><span>i</span> ${state.userEditPresent ? "Re-edit 240" : "Edit line 240"}</button>
          <button type="button" class="tour-chip" data-ht-act="keep_twist"><span>SPC a y</span> Keep</button>
          <button type="button" class="tour-chip" data-ht-act="reject_twist"><span>SPC a d</span> Reject</button>
          <button type="button" class="tour-chip tour-chip-muted" data-ht-act="reset_twist">Reset</button>
        </div>
      </div>
      <div class="spine-titlebar">
        <span class="spine-wordmark">minga</span>
        <span class="spine-title-file">retry.ex <span>lib/minga_agent/retry.ex</span></span>
        <span></span>
      </div>
      <div class="spine-buffer">${bodyRows}</div>
      <div class="spine-modeline">
        <div class="ml-left">
          <span class="ml-pill">NORMAL</span>
          <span class="ml-seg ml-needs">◉ 1 needs you</span>
          <span class="ml-file">retry.ex</span>
          ${mlChange}
          <span>main +11</span>
        </div>
        <div class="ml-right">
          <span class="ml-seg ml-minga">◐ Minga here 2/3</span>
          <span class="ml-dim">elixir</span>
          <span class="ml-dim">240:31</span>
        </div>
      </div>
      <div class="tour-echo" aria-live="polite">${esc(state.twistEcho)}</div>
    `;
  }

  function renderPeek(): void {
    if (!peekPanel) return;
    const specimen = peekPanel.querySelector<HTMLElement>(".spine-specimen");
    if (!specimen) return;
    const worker = HERO_PEEK_WORKERS[state.peekIndex] ?? HERO_PEEK_WORKERS[0]!;
    const strip = HERO_PEEK_WORKERS.map(
      (w, idx) =>
        `<button type="button" class="tour-sib-btn ${idx === state.peekIndex ? "is-current" : ""} ${w.roleClass}" data-ht-peek="${idx}" title="${esc(w.name)}" aria-label="Inspect ${esc(w.name)}">${w.glyph}</button>`,
    ).join("");
    const lines = worker.lines
      .map((l) => `<div class="specimen-row"><span class="${l.cls}">${l.glyph}</span> ${esc(l.text)}</div>`)
      .join("");

    specimen.innerHTML = `
      <div class="tour-live-bar">
        <span class="tour-live-label">TRY IT LIVE · CLICK SIBLINGS OR EDIT YOUR DRAFT</span>
        <div class="tour-live-actions">
          <button type="button" class="tour-chip" data-ht-act="peek_prev"><span>[[</span> Prev</button>
          <button type="button" class="tour-chip" data-ht-act="peek_next"><span>]]</span> Next</button>
          <button type="button" class="tour-chip" data-ht-act="peek_brief"><span>za</span> ${state.peekBriefOpen ? "Fold brief" : "Unfold brief"}</button>
        </div>
      </div>
      <div class="spine-titlebar">
        <span class="spine-wordmark">minga</span>
        <span class="spine-title-file">Refactor retry pipeline <span>parent + subagent split</span></span>
        <span></span>
      </div>
      <div class="specimen-split">
        <div class="specimen-pane">
          <div class="specimen-pane-head">
            <strong>Parent conversation</strong>
            <span class="ml-minga">◐ Working · 1 of 4 reports in</span>
          </div>
          <div class="specimen-row"><span class="specimen-row-you">You</span></div>
          <div class="specimen-row">Audit retry handling, verify edge cases, and add tests before publishing.</div>
          <div class="specimen-row" style="margin-top:0.45rem;"><span class="specimen-row-minga">Minga</span></div>
          <div class="specimen-row"><span class="ml-done">●</span> Read retry.ex and split work across 4 subagents</div>
          <div class="specimen-row"><span class="ml-minga">◐</span> Inspecting ${esc(worker.name)} in right split</div>
          <label class="tour-draft-label" for="ht-parent-draft">Your unsent draft (stays preserved while stepping siblings):</label>
          <input id="ht-parent-draft" class="tour-draft-input" type="text" data-ht-draft value="${esc(state.parentDraft)}">
        </div>
        <div class="specimen-pane">
          <div class="specimen-pane-head">
            <strong>Refactor retry › ${esc(worker.name)}</strong>
            <span class="tour-sib-strip">${strip} <span class="ml-dim">${state.peekIndex + 1} of ${HERO_PEEK_WORKERS.length}</span></span>
          </div>
          <button type="button" class="tour-brief-toggle" data-ht-act="peek_brief">
            ${state.peekBriefOpen ? `▾ Brief: ${esc(worker.brief)}` : "▸ Brief (folded · press za or click to expand)"}
          </button>
          <div style="margin-top:0.35rem;">${lines}</div>
          <div class="specimen-composer">Message ${esc(worker.name)} directly...</div>
        </div>
      </div>
      <div class="spine-modeline">
        <div class="ml-left">
          <span class="ml-pill">NORMAL</span>
          <span class="ml-file">*minga-subagent*</span>
          <span class="ml-dim">]] / [[ siblings · q close</span>
        </div>
        <div class="ml-right">
          <span class="ml-minga">◐ 2 working · ◉ 1 needs you · ● 1 done</span>
        </div>
      </div>
    `;
  }

  function renderTasks(): void {
    if (!tasksPanel) return;
    const specimen = tasksPanel.querySelector<HTMLElement>(".spine-specimen");
    if (!specimen) return;

    const needsOpen = state.approvalState === "needs_you";
    const statusLabel: Record<TourApprovalState, { glyph: string; cls: string; note: string }> = {
      needs_you: { glyph: "◉", cls: "ml-needs", note: "Needs you · 12s" },
      approved_once: { glyph: "◐", cls: "ml-minga", note: "Working · Approved once (y)" },
      approved_session: { glyph: "◐", cls: "ml-minga", note: "Working · Approved for session (a)" },
      approved_turn: { glyph: "◐", cls: "ml-minga", note: "Working · Approved for turn (t)" },
      denied: { glyph: "○", cls: "ml-dim", note: "Stopped · Denied (n); worker paused" },
    };
    const st = statusLabel[state.approvalState];

    const diffBlock = state.showTaskDiff
      ? `<div class="tour-inline-diff">@@ -0,0 +1,4 @@\n+defmodule MingaAgent.UsageLimitTest do\n+  test "classifies 529 overloaded with backoff" do ...</div>`
      : "";

    const queueRows =
      state.queueItems.length > 0
        ? state.queueItems
            .map((item, idx) => `<div class="specimen-row"><span class="ml-dim">${idx + 1}.</span> ${esc(item)}</div>`)
            .join("")
        : `<div class="specimen-row"><span class="ml-dim">Queue empty. Click + Queue prompt to add a follow-up.</span></div>`;

    specimen.innerHTML = `
      <div class="tour-live-bar">
        <span class="tour-live-label">TRY IT LIVE · APPROVE OR REORDER QUEUE</span>
        <div class="tour-live-actions">
          <button type="button" class="tour-chip" data-ht-approve="y"><span>y</span> Approve</button>
          <button type="button" class="tour-chip" data-ht-approve="n"><span>n</span> Deny</button>
          <button type="button" class="tour-chip" data-ht-act="toggle_diff"><span>=</span> ${state.showTaskDiff ? "Hide diff" : "Diff"}</button>
          <button type="button" class="tour-chip" data-ht-act="queue_swap"><span>dd p</span> Reorder queue</button>
          <button type="button" class="tour-chip" data-ht-act="queue_add"><span>+</span> Queue prompt</button>
          ${!needsOpen ? '<button type="button" class="tour-chip tour-chip-muted" data-ht-approve="reset">Reset approval</button>' : ""}
        </div>
      </div>
      <div class="spine-titlebar">
        <span class="spine-wordmark">minga</span>
        <span class="spine-title-file">*minga-tasks* &amp; *minga-queue* <span>buffers in drawers</span></span>
        <span></span>
      </div>
      <div class="specimen-split">
        <div class="specimen-pane">
          <div class="specimen-pane-head">
            <strong>*minga-tasks*</strong>
            <span>${needsOpen ? '<span class="ml-needs">1 needs you</span>' : '<span class="ml-done">0 needs you</span>'} · 1 working · 1 done</span>
          </div>
          <div class="${needsOpen ? "specimen-row-needs" : "tour-row-resolved"}">
            <div class="specimen-row" style="padding:0;"><span class="${st.cls}">${st.glyph}</span> <strong>Add usage limit tests</strong> <span class="ml-dim">· ${esc(st.note)}</span></div>
            <div class="specimen-row" style="padding:0.2rem 0 0;">Create test/minga_agent/usage_limit_test.exs +86</div>
            ${diffBlock}
            ${
              needsOpen
                ? `<div class="tour-inline-keys">
                    <button type="button" class="ca-key-chip" data-ht-approve="y"><span>y</span> Approve once</button>
                    <button type="button" class="ca-key-chip" data-ht-approve="a"><span>a</span> Session</button>
                    <button type="button" class="ca-key-chip" data-ht-approve="t"><span>t</span> Turn</button>
                    <button type="button" class="ca-key-chip" data-ht-approve="n"><span>n</span> Deny</button>
                    <button type="button" class="ca-key-chip" data-ht-act="toggle_diff"><span>=</span> Diff</button>
                  </div>`
                : ""
            }
          </div>
          <div class="specimen-row"><span class="ml-minga">◐</span> Refactor retry pipeline · step 2 of 3</div>
          <div class="specimen-row" style="padding-left:1rem;"><span class="ml-dim">├─</span> <span class="ml-done">●</span> Edge-Case Tester · Done</div>
          <div class="specimen-row" style="padding-left:1rem;"><span class="ml-dim">└─</span> <span class="ml-minga">◐</span> Fact-Check Auditor · Working</div>
        </div>
        <div class="specimen-pane">
          <div class="specimen-pane-head">
            <strong>*minga-queue*</strong>
            <span class="ml-dim">${state.queueItems.length} queued</span>
          </div>
          ${queueRows}
          <div class="tour-inline-keys" style="margin-top:0.55rem;">
            <button type="button" class="ca-key-chip" data-ht-act="queue_swap"><span>dd p</span> Swap 1 &amp; 2</button>
            <button type="button" class="ca-key-chip" data-ht-act="queue_drop_top"><span>dd</span> Drop top</button>
            <button type="button" class="ca-key-chip" data-ht-act="queue_add"><span>o</span> Add</button>
          </div>
        </div>
      </div>
      <div class="spine-modeline">
        <div class="ml-left">
          <span class="ml-pill">NORMAL</span>
          ${needsOpen ? '<span class="ml-needs">◉ 1 needs you</span>' : '<span class="ml-done">● Queue ready</span>'}
          <span class="ml-file">*minga-tasks*</span>
        </div>
        <div class="ml-right">
          <span class="ml-dim">q close</span>
        </div>
      </div>
    `;
  }

  function renderParity(): void {
    if (!parityPanel) return;
    const specimen = parityPanel.querySelector<HTMLElement>(".spine-specimen");
    if (!specimen) return;

    const orbitInfo: Record<TourOrbitState, { glyph: string; word: string; cls: string; ansi16: string; detail: string }> = {
      working: { glyph: "◐", word: "Working", cls: "ml-minga", ansi16: "magenta", detail: "Refactor retry · step 2 of 3" },
      needs_you: { glyph: "◉", word: "Needs you", cls: "ml-needs", ansi16: "yellow", detail: "Approve usage_limit_test.exs (+86)" },
      failed: { glyph: "◆", word: "Failed", cls: "ml-fail", ansi16: "red", detail: "GitHub MCP exited · press r to restart" },
      done: { glyph: "●", word: "Done", cls: "ml-done", ansi16: "green", detail: "2 files ready in *minga-review*" },
    };
    const o = orbitInfo[state.parityOrbit];
    const showMac = state.parityView === "split" || state.parityView === "macos";
    const showTui = state.parityView !== "macos";
    const is16 = state.parityView === "tui_16";

    const macPane = showMac
      ? `<div class="specimen-pane">
          <div class="specimen-pane-head">
            <strong>macOS Desktop (Swift + Metal)</strong>
            <span class="ml-minga">Vector marks + CoreText</span>
          </div>
          <div class="specimen-row"><span class="${o.cls}">${o.glyph}</span> <strong>${o.word}</strong> · ${esc(o.detail)}</div>
          <div class="specimen-row"><span class="ml-dim">Surface:</span> Same BEAM state, exact vector Twist gutter, smooth Metal scroll</div>
          <div class="specimen-row"><span class="ml-dim">Discovery:</span> Hold ⌘ on macOS · click any visible action</div>
        </div>`
      : "";

    const tuiPane = showTui
      ? `<div class="specimen-pane">
          <div class="specimen-tui-frame ${is16 ? "is-ansi16" : ""}">
            <div class="specimen-tui-top">
              <span>*minga-review* · ${o.glyph} ${o.word}</span>
              <span>${is16 ? "Go TUI · 16-color safe" : "Go Terminal UI · Truecolor"}</span>
            </div>
            <div>${esc(o.detail)}</div>
            <div>&nbsp;├─ lib/minga_agent/retry.ex (@@ 238 +4 -1)</div>
            <div>&nbsp;└─ test/retry_test.exs (+28)</div>
            <div class="specimen-tui-foot">${is16 ? `ANSI ${o.ansi16} fallback · shape still unmistakable · ` : ""}y keep · n reject · = diff · q close</div>
          </div>
        </div>`
      : "";

    specimen.innerHTML = `
      <div class="tour-live-bar">
        <span class="tour-live-label">SYNC ONE BEAM STATE ACROSS CLIENTS</span>
        <div class="tour-live-actions">
          <button type="button" class="tour-chip ${state.parityOrbit === "working" ? "is-active" : ""}" data-ht-orbit="working">◐ Working</button>
          <button type="button" class="tour-chip ${state.parityOrbit === "needs_you" ? "is-active" : ""}" data-ht-orbit="needs_you">◉ Needs you</button>
          <button type="button" class="tour-chip ${state.parityOrbit === "failed" ? "is-active" : ""}" data-ht-orbit="failed">◆ Failed</button>
          <button type="button" class="tour-chip ${state.parityOrbit === "done" ? "is-active" : ""}" data-ht-orbit="done">● Done</button>
          <span class="tour-sep" aria-hidden="true">|</span>
          <button type="button" class="tour-chip ${state.parityView === "split" ? "is-active" : ""}" data-ht-pview="split">Side-by-side</button>
          <button type="button" class="tour-chip ${state.parityView === "macos" ? "is-active" : ""}" data-ht-pview="macos">macOS only</button>
          <button type="button" class="tour-chip ${state.parityView === "tui_16" ? "is-active" : ""}" data-ht-pview="tui_16">16-color TUI</button>
        </div>
      </div>
      <div class="spine-titlebar">
        <span class="spine-wordmark">minga</span>
        <span class="spine-title-file">*minga-review* <span>${state.parityView === "tui_16" ? "16-color SSH degradation" : "macOS vs. Terminal"}</span></span>
        <span></span>
      </div>
      <div class="specimen-split ${state.parityView !== "split" ? "is-single" : ""}">
        ${macPane}
        ${tuiPane}
      </div>
      <div class="spine-modeline">
        <div class="ml-left">
          <span class="ml-pill">NORMAL</span>
          <span class="ml-file">*minga-review*</span>
          <span class="${o.cls}">${o.glyph} ${o.word}</span>
        </div>
        <div class="ml-right">
          <span class="ml-dim">One canonical state · Truecolor / 256 / 16-color</span>
        </div>
      </div>
    `;
  }

  function renderAll(): void {
    renderTwist();
    renderPeek();
    renderTasks();
    renderParity();
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;

    const actBtn = target.closest<HTMLElement>("[data-ht-act]");
    if (actBtn) {
      const act = actBtn.getAttribute("data-ht-act");
      if (act === "undo_yours") state = reduceHeroTour(state, { type: "undo_yours" });
      else if (act === "toggle_edit") state = reduceHeroTour(state, { type: "toggle_edit" });
      else if (act === "keep_twist") state = reduceHeroTour(state, { type: "keep_twist" });
      else if (act === "reject_twist") state = reduceHeroTour(state, { type: "reject_twist" });
      else if (act === "reset_twist") state = reduceHeroTour(state, { type: "reset_twist" });
      else if (act === "peek_prev") state = reduceHeroTour(state, { type: "peek_step", delta: -1 });
      else if (act === "peek_next") state = reduceHeroTour(state, { type: "peek_step", delta: 1 });
      else if (act === "peek_brief") state = reduceHeroTour(state, { type: "peek_toggle_brief" });
      else if (act === "toggle_diff") state = reduceHeroTour(state, { type: "toggle_diff" });
      else if (act === "queue_drop_top") state = reduceHeroTour(state, { type: "queue_drop_top" });
      else if (act === "queue_swap") state = reduceHeroTour(state, { type: "queue_swap" });
      else if (act === "queue_add") state = reduceHeroTour(state, { type: "queue_add" });
      renderAll();
      return;
    }

    const peekBtn = target.closest<HTMLElement>("[data-ht-peek]");
    if (peekBtn) {
      const idx = Number(peekBtn.getAttribute("data-ht-peek"));
      if (!Number.isNaN(idx)) {
        state = reduceHeroTour(state, { type: "peek_select", index: idx });
        renderPeek();
      }
      return;
    }

    const appBtn = target.closest<HTMLElement>("[data-ht-approve]");
    if (appBtn) {
      const choice = appBtn.getAttribute("data-ht-approve");
      if (choice === "y" || choice === "a" || choice === "t" || choice === "n" || choice === "reset") {
        state = reduceHeroTour(state, { type: "approve", choice });
        renderTasks();
      }
      return;
    }

    const orbitBtn = target.closest<HTMLElement>("[data-ht-orbit]");
    if (orbitBtn) {
      const orbit = orbitBtn.getAttribute("data-ht-orbit");
      if (orbit === "working" || orbit === "needs_you" || orbit === "failed" || orbit === "done") {
        state = reduceHeroTour(state, { type: "set_parity_orbit", orbit });
        renderParity();
      }
      return;
    }

    const pvBtn = target.closest<HTMLElement>("[data-ht-pview]");
    if (pvBtn) {
      const view = pvBtn.getAttribute("data-ht-pview");
      if (view === "split" || view === "macos" || view === "tui_truecolor" || view === "tui_16") {
        state = reduceHeroTour(state, { type: "set_parity_view", view });
        renderParity();
      }
    }
  });

  root.addEventListener("input", (event) => {
    const target = event.target as HTMLInputElement | null;
    if (target?.matches("[data-ht-draft]")) {
      state = reduceHeroTour(state, { type: "set_draft", text: target.value });
    }
  });

  renderAll();
}

export function mountMarksThemeSwitcher(root: HTMLElement): void {
  let activeTheme: MarksThemeId = "catppuccin_frappe";
  const section = root.closest("section");
  if (!section) return;

  function applyTheme(): void {
    const r = SEMANTIC_MARK_THEMES[activeTheme];
    const buttons = (Object.keys(SEMANTIC_MARK_THEMES) as MarksThemeId[])
      .map(
        (id) =>
          `<button type="button" class="seg-btn ${id === activeTheme ? "is-active" : ""}" data-mark-theme="${id}">${SEMANTIC_MARK_THEMES[id].label}</button>`,
      )
      .join("");

    root.innerHTML = `
      <div class="marks-theme-bar">
        <div class="marks-theme-head">
          <span class="marks-theme-k">PREVIEW SEMANTIC THEME ROLES LIVE</span>
          <div class="seg-group" role="group" aria-label="Preview Twist and Orbit theme roles">${buttons}</div>
        </div>
        <div class="marks-role-tokens" style="background:${r.bg};border-color:${r.border};color:${r.text};">
          <span><i style="background:${r.minga}"></i>minga <code>${r.minga}</code></span>
          <span><i style="background:${r.you}"></i>you <code>${r.you}</code></span>
          <span><i style="background:${r.needsYou}"></i>needs_you <code>${r.needsYou}</code></span>
          <span><i style="background:${r.failure}"></i>failure <code>${r.failure}</code></span>
          <span><i style="background:${r.done}"></i>done <code>${r.done}</code></span>
        </div>
      </div>
    `;

    const twistSwatches = section!.querySelectorAll<HTMLElement>(".twist-swatch");
    const twistSvgs = [
      twistCrossSvg(r.minga, r.mingaDim, r.bg),
      twistPairSvg(r.you, r.minga),
      twistSingleSvg(r.you, 1, 1.8),
      twistSingleSvg(r.minga, 0.55, 1.6),
    ];
    twistSwatches.forEach((el, idx) => {
      el.style.background = r.bg;
      el.style.borderColor = r.border;
      if (twistSvgs[idx]) el.innerHTML = twistSvgs[idx]!;
    });

    const orbitSvgs = [
      `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.5" fill="none" stroke="${r.minga}" stroke-opacity="0.32" stroke-width="1.5"/><path d="M8 2.5 A5.5 5.5 0 0 1 13.5 8" fill="none" stroke="${r.minga}" stroke-width="1.5" stroke-linecap="round"/><circle cx="13.5" cy="8" r="2.1" fill="${r.minga}"/></svg>`,
      `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6" fill="${r.needsYou}" fill-opacity="0.3"/><circle cx="8" cy="8" r="3.4" fill="${r.needsYou}"/></svg>`,
      `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="3" fill="none" stroke="${r.waiting}" stroke-width="1.6"/></svg>`,
      `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><rect x="4.6" y="4.6" width="6.8" height="6.8" rx="1.2" fill="${r.failure}" transform="rotate(45 8 8)"/></svg>`,
      `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="3.4" fill="${r.done}"/></svg>`,
    ];
    const orbitRows = section!.querySelectorAll<HTMLElement>(".orbit-row");
    orbitRows.forEach((row, idx) => {
      const existingSvg = row.querySelector("svg");
      if (existingSvg && orbitSvgs[idx]) {
        existingSvg.outerHTML = orbitSvgs[idx]!;
      }
    });
  }

  root.addEventListener("click", (event) => {
    const btn = (event.target as HTMLElement | null)?.closest<HTMLElement>("[data-mark-theme]");
    if (!btn) return;
    const id = btn.getAttribute("data-mark-theme") as MarksThemeId | null;
    if (id && id in SEMANTIC_MARK_THEMES) {
      activeTheme = id;
      applyTheme();
    }
  });

  applyTheme();
}
