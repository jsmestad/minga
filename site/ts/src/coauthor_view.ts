/* Thin DOM renderer for Lesson 03: Live Parallel-Agent & Twist Co-Authoring Simulator. */

import { completeMission, getCompletedMissions } from "./progress.ts";
import {
  COAUTHOR_MISSIONS,
  answerApproval,
  autoOpenTasksWithLockout,
  closeCoAuthorDrawer,
  countNeedsYou,
  createCoAuthorState,
  editInsideTwist,
  jumpNextChange,
  openSubagentPeek,
  openTasksDrawer,
  reviewCurrentChange,
  stepPeekSibling,
  toggleBriefFold,
  toggleCoAuthorActMenu,
  undoUserEdit,
  type CoAuthorMissionId,
  type CoAuthorState,
  type OrbitState,
} from "./coauthor_state.ts";

const SVG_CROSS =
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="24" viewBox="0 0 10 26" aria-hidden="true"><path d="M7 5 C7 11, 3 11, 3 17 L3 26" fill="none" stroke="#74628d" stroke-width="2.6" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 26" fill="none" stroke="#303446" stroke-width="5" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 26" fill="none" stroke="#ca9ee6" stroke-width="2.6" stroke-linecap="round"/></svg>';
const SVG_CONT =
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="24" viewBox="0 0 10 26" aria-hidden="true"><path d="M3 0 L3 26" stroke="#74628d" stroke-width="2.6"/><path d="M7 0 L7 26" stroke="#ca9ee6" stroke-width="2.6"/></svg>';
const SVG_SHARED =
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="24" viewBox="0 0 10 26" aria-hidden="true"><path d="M3 0 L3 26" stroke="#8caaee" stroke-width="2.6"/><path d="M7 0 L7 26" stroke="#ca9ee6" stroke-width="2.6"/></svg>';
const SVG_END =
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="24" viewBox="0 0 10 26" aria-hidden="true"><path d="M3 0 L3 19" stroke="#74628d" stroke-width="2.6" stroke-linecap="round"/><path d="M7 0 L7 19" stroke="#ca9ee6" stroke-width="2.6" stroke-linecap="round"/></svg>';
const SVG_KEPT =
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="24" viewBox="0 0 10 26" aria-hidden="true"><path d="M5 0 L5 26" stroke="#ca9ee6" stroke-opacity="0.48" stroke-width="1.6"/></svg>';

function esc(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function orbitGlyph(orbit: OrbitState): { glyph: string; cls: string; label: string } {
  switch (orbit) {
    case "working":
      return { glyph: "◐", cls: "ml-minga", label: "Working" };
    case "needs_you":
      return { glyph: "◉", cls: "ml-needs", label: "Needs you" };
    case "done":
      return { glyph: "●", cls: "ml-done", label: "Done" };
    case "failed":
      return { glyph: "◆", cls: "role-fail", label: "Failed" };
    case "waiting":
      return { glyph: "○", cls: "ml-dim", label: "Waiting" };
    case "stopped":
      return { glyph: "○", cls: "ml-dim", label: "Stopped" };
  }
}

export function mountCoAuthorSim(root: HTMLElement): void {
  const saved = Array.from(getCompletedMissions("agents")) as CoAuthorMissionId[];
  let state: CoAuthorState = createCoAuthorState(saved);
  let unlockTimer: number | undefined;

  function update(next: CoAuthorState): void {
    for (const m of next.completed) {
      if (!state.completed.has(m)) {
        completeMission("agents", m);
      }
    }
    state = next;
    render();
  }

  function scheduleUnlockCheck(): void {
    if (unlockTimer !== undefined) window.clearTimeout(unlockTimer);
    const delay = state.lockoutUntilMs - Date.now();
    if (delay > 0) {
      unlockTimer = window.setTimeout(() => {
        render();
      }, delay + 20);
    }
  }

  function renderDrawer(): string {
    if (state.activeDrawer === "tasks") {
      const locked = Date.now() < state.lockoutUntilMs;
      const rows = [...state.workers]
        .sort((a, b) => (a.state === "needs_you" ? -1 : b.state === "needs_you" ? 1 : 0))
        .map((w) => {
          const o = orbitGlyph(w.state);
          if (w.approvalRequest && w.state === "needs_you") {
            return `
              <div class="specimen-row-needs">
                <div class="specimen-row" style="padding:0;">
                  <span class="${o.cls}">${o.glyph}</span>
                  <strong>${esc(w.approvalRequest.title)}</strong>
                  <span class="ml-dim">· ${esc(o.label)}</span>
                  ${locked ? '<span class="ca-lock-badge">300 ms lockout active</span>' : ""}
                </div>
                <div class="specimen-row" style="padding:0.2rem 0 0;">${esc(w.approvalRequest.detail)}</div>
                <div class="ca-approval-btns">
                  <button type="button" class="ca-key-chip" data-ca-approve="y"><span>y</span> Approve once</button>
                  <button type="button" class="ca-key-chip" data-ca-approve="a"><span>a</span> Session</button>
                  <button type="button" class="ca-key-chip" data-ca-approve="t"><span>t</span> Turn</button>
                  <button type="button" class="ca-key-chip" data-ca-approve="n"><span>n</span> Deny</button>
                </div>
              </div>`;
          }
          return `
            <div class="specimen-row">
              <span class="${o.cls}">${o.glyph}</span>
              <strong>${esc(w.name)}</strong>
              <span class="ml-dim">· ${esc(o.label)} · ${esc(w.summary)}</span>
            </div>`;
        })
        .join("");

      return `
        <div class="sb-drawer" role="region" aria-label="Tasks drawer">
          <div class="sb-drawer-head">
            <span><strong>*minga-tasks*</strong> <span class="ml-dim">needs-you sorted first · 300 ms anti-misfire lockout</span></span>
            <button type="button" class="sb-drawer-close" data-ca-action="close-drawer">q close</button>
          </div>
          <div class="ca-drawer-body">${rows}</div>
        </div>`;
    }

    if (state.activeDrawer === "peek") {
      const worker = state.workers[state.peekIndex] ?? state.workers[0];
      if (!worker) return "";
      const o = orbitGlyph(worker.state);
      const strip = state.workers
        .map((w, i) => {
          const wo = orbitGlyph(w.state);
          return `<button type="button" class="ca-sib-glyph ${i === state.peekIndex ? "is-current" : ""} ${wo.cls}" data-ca-peek-idx="${i}" title="${esc(w.name)}">${wo.glyph}</button>`;
        })
        .join("");
      const steps = worker.steps.map((s) => `<div class="specimen-row"><span class="${o.cls}">${o.glyph}</span> ${esc(s)}</div>`).join("");

      return `
        <div class="ca-peek-split" role="region" aria-label="Subagent Peek right split">
          <div class="ca-peek-parent">
            <div class="specimen-pane-head">
              <strong>Parent conversation</strong>
              <span class="ml-minga">Draft preserved</span>
            </div>
            <div class="specimen-row"><span class="ml-dim">Unsent draft stays untouched while you inspect siblings:</span></div>
            <label class="sr-only" for="ca-draft-input">Parent composer draft</label>
            <input id="ca-draft-input" class="ca-draft-input" type="text" data-ca-draft>
          </div>
          <div class="ca-peek-worker">
            <div class="specimen-pane-head">
              <strong>Refactor retry › ${esc(worker.name)}</strong>
              <span class="ca-sib-strip">${strip} <span class="ml-dim">${state.peekIndex + 1} of ${state.workers.length}</span></span>
            </div>
            <button type="button" class="ca-brief-btn" data-ca-action="toggle-brief">
              ${state.briefFolded ? "▸ Brief (folded · press za to unfold)" : `▾ Brief: ${esc(worker.brief)}`}
            </button>
            ${steps}
            <div class="ca-peek-actions">
              <button type="button" class="ca-key-chip" data-ca-action="peek-prev"><span>[[</span> Prev sibling</button>
              <button type="button" class="ca-key-chip" data-ca-action="peek-next"><span>]]</span> Next sibling</button>
              <button type="button" class="ca-key-chip" data-ca-action="close-drawer"><span>q</span> Close split</button>
            </div>
          </div>
        </div>`;
    }

    return "";
  }

  function render(): void {
    const needsCount = countNeedsYou(state);
    const remainingChanges = (state.change1 === "unreviewed" ? 1 : 0) + (state.change2 === "unreviewed" ? 1 : 0);
    const curStatus = state.cursorChange === 1 ? state.change1 : state.change2;

    const g1Top = state.change1 === "unreviewed" ? SVG_CROSS : state.change1 === "kept" ? SVG_KEPT : "";
    const g1Mid = state.change1 === "unreviewed" ? SVG_CONT : state.change1 === "kept" ? SVG_KEPT : "";
    const g1L240 = state.change1 === "unreviewed" ? (state.userEditPresent ? SVG_SHARED : SVG_CONT) : state.change1 === "kept" ? SVG_KEPT : "";
    const g1End = state.change1 === "unreviewed" ? SVG_END : state.change1 === "kept" ? SVG_KEPT : "";
    const g2 = state.change2 === "unreviewed" ? SVG_CROSS : state.change2 === "kept" ? SVG_KEPT : "";

    const c1Hl = state.change1 === "unreviewed" ? "spine-line-hl" : "";
    const c1Rej = state.change1 === "rejected" ? "lab-line-rejected" : "";
    const c2Hl = state.change2 === "unreviewed" ? "spine-line-hl" : "";
    const c2Rej = state.change2 === "rejected" ? "lab-line-rejected" : "";

    const line240Code = state.userEditPresent
      ? '    <span class="cnum">529</span> -&gt; {<span class="cat">:overloaded</span>, backoff_ms(<span class="cnum">2</span>)} <span class="ccm"># your edit</span>'
      : '    <span class="cnum">529</span> -&gt; {<span class="cat">:overloaded</span>, backoff_ms(<span class="cnum">1</span>)}';

    const actMenuHtml =
      state.actMenuOpen && curStatus === "unreviewed"
        ? `
          <div class="lab-act-menu">
            <div class="lab-act-head">
              <span>○ Minga's change ${state.cursorChange} of 2 · ${state.cursorChange === 1 ? "4 lines" : "1 line"} · unreviewed</span>
              <button type="button" class="sb-drawer-close" data-ca-action="act">esc close</button>
            </div>
            <div class="lab-act-decision">
              <button type="button" class="lab-act-half lab-act-keep" data-ca-action="keep">
                <strong><span>y</span> Keep</strong>
                <small>accept ${state.cursorChange === 1 ? "4 lines" : "1 line"}</small>
              </button>
              <button type="button" class="lab-act-half" data-ca-action="reject">
                <strong><span>n</span> Reject</strong>
                <small>${state.cursorChange === 1 ? "removes 4 lines, restores 1" : "removes 1 line"}</small>
              </button>
            </div>
          </div>`
        : "";

    const missionsHtml = COAUTHOR_MISSIONS.map((m) => {
      const done = state.completed.has(m.id);
      return `
        <li class="mission-row ${done ? "is-done" : ""}">
          <span class="mission-check" aria-hidden="true">${done ? "●" : "○"}</span>
          <div>
            <strong>${esc(m.label)}</strong>
            <span>${esc(m.hint)}</span>
          </div>
        </li>`;
    }).join("");

    root.innerHTML = `
      <div class="workbench-shell">
        <div class="workbench-main">
          <div class="lab-toolbar" role="toolbar" aria-label="Co-authoring actions">
            <button type="button" class="lab-cmd" data-ca-action="undo"><span>u</span> Undo yours</button>
            <button type="button" class="lab-cmd" data-ca-action="edit"><span>i</span> ${state.userEditPresent ? "Re-mark edit" : "Edit line 240"}</button>
            <button type="button" class="lab-cmd" data-ca-action="next"><span>]h</span> Next change</button>
            <button type="button" class="lab-cmd" data-ca-action="keep"><span>SPC a y</span> Keep</button>
            <button type="button" class="lab-cmd" data-ca-action="reject"><span>SPC a d</span> Reject</button>
            <button type="button" class="lab-cmd" data-ca-action="act"><span>g.</span> Act menu</button>
          </div>
          <div class="lab-toolbar ca-toolbar-row2" role="toolbar" aria-label="Parallel agent drawers">
            <button type="button" class="lab-cmd" data-ca-action="tasks"><span>SPC a a</span> Tasks</button>
            <button type="button" class="lab-cmd" data-ca-action="test-lockout"><span>300ms</span> Test stray y guard</button>
            <button type="button" class="lab-cmd" data-ca-action="peek"><span>SPC a i</span> Subagent Peek</button>
            <button type="button" class="lab-cmd lab-cmd-muted" data-ca-action="reset">Reset</button>
          </div>

          <div class="spine-specimen lab-specimen" tabindex="0" data-ca-stage aria-label="Interactive co-authoring viewport. Focus and type u, i, ]h, g., SPC a y, SPC a d, SPC a a, SPC a i, [[, ]], za, y/a/t/n, or q.">
            <div class="spine-titlebar">
              <span class="spine-wordmark">minga</span>
              <span class="spine-title-file">retry.ex <span>lib/minga_agent</span></span>
              <span></span>
            </div>

            ${actMenuHtml}

            <div class="spine-buffer">
              <div class="spine-line"><span class="spine-ln">237</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter"></span><span class="spine-code"><span class="ckw">def</span> classify_status(status, headers) <span class="ckw">do</span></span></div>
              <div class="spine-line ${c1Hl} ${c1Rej} ${state.cursorChange === 1 ? "lab-cursor" : ""}"><span class="spine-ln">238</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter">${g1Top}</span><span class="spine-code">  <span class="ckw">case</span> status <span class="ckw">do</span></span></div>
              <div class="spine-line ${c1Hl} ${c1Rej}"><span class="spine-ln">239</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter">${g1Mid}</span><span class="spine-code">    <span class="cnum">429</span> -&gt; {<span class="cat">:rate_limited</span>, parse_retry_after(headers)}</span></div>
              <div class="spine-line ${c1Hl} ${c1Rej}"><span class="spine-ln">240</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter">${g1L240}</span><span class="spine-code">${line240Code}</span></div>
              <div class="spine-line ${c1Hl} ${c1Rej}"><span class="spine-ln">241</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter">${g1End}</span><span class="spine-code">    code <span class="ckw">when</span> code &gt;= <span class="cnum">500</span> -&gt; {<span class="cat">:retryable</span>, backoff_ms(<span class="cnum">1</span>)}</span></div>
              <div class="spine-line"><span class="spine-ln">242</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter"></span><span class="spine-code">    _ -&gt; {<span class="cat">:fatal</span>, status}</span></div>
              <div class="spine-line ${c2Hl} ${c2Rej} ${state.cursorChange === 2 ? "lab-cursor" : ""}"><span class="spine-ln">245</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter">${g2}</span><span class="spine-code"><span class="ckw">defp</span> backoff_ms(attempt), <span class="ckw">do:</span> min(<span class="cnum">30_000</span>, <span class="cnum">250</span> * attempt)</span></div>
            </div>

            ${renderDrawer()}

            <div class="spine-modeline">
              <div class="ml-left">
                <span class="ml-pill">NORMAL</span>
                ${needsCount > 0 ? `<button type="button" class="ml-seg ml-needs ml-clickable" data-ca-action="tasks">◉ ${needsCount} needs you</button>` : ""}
                <span class="ml-file">retry.ex</span>
                ${remainingChanges > 0 && curStatus === "unreviewed" ? `<span class="ml-minga">change ${state.cursorChange}/${remainingChanges}</span>` : ""}
              </div>
              <div class="ml-right">
                <button type="button" class="ml-seg ml-minga ml-clickable" data-ca-action="peek">◐ 1 working · ${state.workers.filter((w) => w.state === "done").length} done</button>
                <span class="ml-dim">${state.cursorChange === 1 ? "238:3" : "245:1"}</span>
              </div>
            </div>
          </div>

          <div class="lab-note" aria-live="polite">${esc(state.lastEvent)}</div>
        </div>

        <aside class="workbench-missions" aria-label="Co-authoring missions">
          <div class="missions-head">
            <span>MISSIONS</span>
            <span>${state.completed.size} / ${COAUTHOR_MISSIONS.length}</span>
          </div>
          <p class="missions-sub">Feel each co-authoring guarantee directly on the buffer, tasks drawer, and subagent split.</p>
          <ul class="mission-list">${missionsHtml}</ul>
        </aside>
      </div>`;
    const draftInput = root.querySelector<HTMLInputElement>("[data-ca-draft]");
    if (draftInput) draftInput.value = state.parentDraft;
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;

    const approveBtn = target.closest<HTMLElement>("[data-ca-approve]");
    if (approveBtn) {
      const ch = approveBtn.getAttribute("data-ca-approve");
      if (ch === "y" || ch === "a" || ch === "t" || ch === "n") {
        update(answerApproval(state, ch, Date.now()));
      }
      return;
    }

    const peekIdxBtn = target.closest<HTMLElement>("[data-ca-peek-idx]");
    if (peekIdxBtn) {
      const idx = Number(peekIdxBtn.getAttribute("data-ca-peek-idx"));
      const delta: 1 | -1 = idx >= state.peekIndex ? 1 : -1;
      const stepped = stepPeekSibling({ ...state, peekIndex: (idx - delta + state.workers.length) % state.workers.length }, delta);
      update(stepped);
      return;
    }

    const actBtn = target.closest<HTMLElement>("[data-ca-action]");
    if (!actBtn) return;
    const action = actBtn.getAttribute("data-ca-action");

    if (action === "undo") update(undoUserEdit(state));
    else if (action === "edit") update(editInsideTwist(state));
    else if (action === "next") update(jumpNextChange(state));
    else if (action === "keep") update(reviewCurrentChange(state, "kept"));
    else if (action === "reject") update(reviewCurrentChange(state, "rejected"));
    else if (action === "act") update(toggleCoAuthorActMenu(state));
    else if (action === "tasks") update(openTasksDrawer(state));
    else if (action === "peek") update(openSubagentPeek(state));
    else if (action === "peek-next") update(stepPeekSibling(state, 1));
    else if (action === "peek-prev") update(stepPeekSibling(state, -1));
    else if (action === "toggle-brief") update(toggleBriefFold(state));
    else if (action === "close-drawer") update(closeCoAuthorDrawer(state));
    else if (action === "test-lockout") {
      const now = Date.now();
      const opened = autoOpenTasksWithLockout(state, now);
      const guarded = answerApproval(opened, "y", now + 120);
      update(guarded);
      scheduleUnlockCheck();
    } else if (action === "reset") {
      update(createCoAuthorState(state.completed));
    }
  });

  let pending = "";

  root.addEventListener("input", (event) => {
    const target = event.target as HTMLInputElement | null;
    if (target?.matches("[data-ca-draft]")) {
      state = { ...state, parentDraft: target.value };
    }
  });

  root.addEventListener("keydown", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target || target.matches("input, textarea, select")) return;
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const key = event.key;

    const finish = (next: CoAuthorState): void => {
      event.preventDefault();
      pending = "";
      update(next);
      root.querySelector<HTMLElement>("[data-ca-stage]")?.focus();
    };

    if (key === "Escape" || key === "q") {
      if (pending) {
        event.preventDefault();
        pending = "";
        return;
      }
      if (state.activeDrawer !== "none" || state.actMenuOpen) {
        finish(closeCoAuthorDrawer(state));
      }
      return;
    }

    if (state.activeDrawer === "tasks" && (key === "y" || key === "a" || key === "t" || key === "n")) {
      finish(answerApproval(state, key, Date.now()));
      return;
    }

    if (pending === "SPC") {
      event.preventDefault();
      pending = key === "a" ? "SPC a" : "";
      return;
    }
    if (pending === "SPC a") {
      if (key === "y") return finish(reviewCurrentChange(state, "kept"));
      if (key === "d") return finish(reviewCurrentChange(state, "rejected"));
      if (key === "a") return finish(openTasksDrawer(state));
      if (key === "i") return finish(openSubagentPeek(state));
      pending = "";
      return;
    }
    if (pending === "g") {
      if (key === ".") return finish(toggleCoAuthorActMenu(state));
      pending = "";
      return;
    }
    if (pending === "]") {
      if (key === "h") return finish(jumpNextChange(state));
      if (key === "]" && state.activeDrawer === "peek") return finish(stepPeekSibling(state, 1));
      pending = "";
      return;
    }
    if (pending === "[") {
      if (key === "[" && state.activeDrawer === "peek") return finish(stepPeekSibling(state, -1));
      pending = "";
      return;
    }
    if (pending === "z") {
      if (key === "a" && state.activeDrawer === "peek") return finish(toggleBriefFold(state));
      pending = "";
      return;
    }

    if (key === " ") {
      event.preventDefault();
      pending = "SPC";
      return;
    }
    if (key === "g" || key === "]" || key === "[" || key === "z") {
      event.preventDefault();
      pending = key;
      return;
    }
    if (key === "u") return finish(undoUserEdit(state));
    if (key === "i") return finish(editInsideTwist(state));
  });

  render();
}
