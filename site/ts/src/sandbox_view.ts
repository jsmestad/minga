/* Thin DOM renderer and keyboard/mouse controller for Lesson 02: Playable Mini-Minga Sandbox. */

import { completeMission, getCompletedMissions } from "./progress.ts";
import {
  SANDBOX_MISSIONS,
  createSandboxState,
  dismissOverlay,
  handleSandboxKey,
  openActMenu,
  openHover,
  openSwitcher,
  openWhichKey,
  resolveActDecision,
  setSandboxClient,
  setSandboxProfile,
  togglePinSelected,
  type SandboxMissionId,
  type SandboxState,
} from "./sandbox_state.ts";

const SVG_TWIST_CROSS =
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="24" viewBox="0 0 10 26" aria-hidden="true"><path d="M7 5 C7 11, 3 11, 3 17 L3 26" fill="none" stroke="#74628d" stroke-width="2.6" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 26" fill="none" stroke="#303446" stroke-width="5" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 26" fill="none" stroke="#ca9ee6" stroke-width="2.6" stroke-linecap="round"/></svg>';
const SVG_TWIST_BODY =
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="24" viewBox="0 0 10 26" aria-hidden="true"><path d="M3 0 L3 26" stroke="#74628d" stroke-width="2.6"/><path d="M7 0 L7 26" stroke="#ca9ee6" stroke-width="2.6"/></svg>';
const SVG_TWIST_KEPT =
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="24" viewBox="0 0 10 26" aria-hidden="true"><path d="M5 0 L5 26" stroke="#ca9ee6" stroke-opacity="0.48" stroke-width="1.6"/></svg>';

function esc(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function mountSandbox(root: HTMLElement): void {
  const saved = Array.from(getCompletedMissions("editing")) as SandboxMissionId[];
  let state: SandboxState = createSandboxState(saved);

  function update(next: SandboxState): void {
    for (const m of next.completed) {
      if (!state.completed.has(m)) {
        completeMission("editing", m);
      }
    }
    state = next;
    render();
  }

  function renderOverlay(): string {
    if (state.overlay.kind === "which_key") {
      if (state.overlay.prefix === "SPC") {
        return `
          <div class="sb-whichkey" role="dialog" aria-label="Which-key menu">
            <div class="sb-wk-head"><span>SPC ›</span><span class="ml-dim">pause after SPC · click or press key · esc close</span></div>
            <div class="sb-wk-grid">
              <button type="button" class="sb-wk-item" data-sb-cmd="wk-a"><span class="sb-wk-k">a</span><span class="sb-wk-grp">Minga ›</span><span class="ml-needs">1 needs you</span></button>
              <button type="button" class="sb-wk-item" data-sb-cmd="switcher"><span class="sb-wk-k">,</span><span>Switch buffer</span><span class="ml-dim">SPC b b</span></button>
              <button type="button" class="sb-wk-item" data-sb-cmd="act"><span class="sb-wk-k">g.</span><span>Act menu</span><span class="ml-dim">right-click</span></button>
              <button type="button" class="sb-wk-item" data-sb-cmd="hover"><span class="sb-wk-k">K</span><span>Hover peek</span><span class="ml-dim">K K focus</span></button>
            </div>
          </div>`;
      }
      return `
        <div class="sb-whichkey" role="dialog" aria-label="Minga leader group">
          <div class="sb-wk-head"><span>SPC › a  Minga</span><span class="ml-dim">esc close</span></div>
          <div class="sb-wk-grid">
            <button type="button" class="sb-wk-item" data-sb-cmd="keep"><span class="sb-wk-k">y</span><span>Keep change</span><span class="ml-dim">SPC a y</span></button>
            <button type="button" class="sb-wk-item" data-sb-cmd="reject"><span class="sb-wk-k">d</span><span>Reject change</span><span class="ml-dim">SPC a d</span></button>
            <button type="button" class="sb-wk-item" data-sb-cmd="switcher"><span class="sb-wk-k">,</span><span>Switcher drawer</span><span class="ml-dim">SPC ,</span></button>
            <button type="button" class="sb-wk-item" data-sb-cmd="dismiss-esc"><span class="sb-wk-k">esc</span><span>Back to code</span><span class="ml-dim">transient</span></button>
          </div>
        </div>`;
    }

    if (state.overlay.kind === "switcher") {
      const sel = state.overlay.selectedIndex;
      const rows = state.files
        .map((file, idx) => {
          const isSel = idx === sel;
          return `
            <div class="sb-sw-row ${isSel ? "is-selected" : ""}" data-sb-open="${idx}">
              <span class="sb-sw-sec">${esc(file.section)}</span>
              <strong>${esc(file.name)}</strong>
              <span class="ml-dim">${esc(file.dir)}</span>
              <span class="sb-sw-note">${esc(file.statusNote)}</span>
              <button type="button" class="sb-sw-pin" data-sb-pin="${idx}">${file.pinned ? "Unpin" : "Pin (⌃T)"}</button>
            </div>`;
        })
        .join("");

      return `
        <div class="sb-drawer" role="dialog" aria-label="File switcher drawer">
          <div class="sb-drawer-head">
            <span><strong>Find file ›</strong> <span class="ml-dim">typing filters · ⌃J/⌃K move · ⌃T pin · ↩ open</span></span>
            <button type="button" class="sb-drawer-close" data-sb-cmd="dismiss-q">q close</button>
          </div>
          <div class="sb-sw-list">${rows}</div>
        </div>`;
    }

    if (state.overlay.kind === "act_menu") {
      const keepSel = state.overlay.selected === "keep";
      return `
        <div class="sb-act" role="dialog" aria-label="Direction A Act Menu">
          <div class="sb-act-head">
            <span>○ Minga's change 1 of 2 · 4 lines · ${state.changeStatus}</span>
            <button type="button" class="sb-drawer-close" data-sb-cmd="dismiss-esc">esc close</button>
          </div>
          <div class="sb-act-decision">
            <button type="button" class="sb-act-half ${keepSel ? "is-preselected" : ""}" data-sb-cmd="keep">
              <strong><span>y</span> Keep</strong>
              <small>accept 4 lines</small>
            </button>
            <button type="button" class="sb-act-half ${!keepSel ? "is-preselected" : ""}" data-sb-cmd="reject">
              <strong><span>n</span> Reject</strong>
              <small>removes 4 lines, restores 1</small>
            </button>
          </div>
          <div class="sb-act-list">
            <button type="button" class="sb-act-row" data-sb-cmd="hover"><span>d  Show diff / details</span><span class="ml-dim">K</span></button>
            <button type="button" class="sb-act-row" data-sb-cmd="switcher"><span>f  Switch buffer</span><span class="ml-dim">SPC ,</span></button>
          </div>
        </div>`;
    }

    if (state.overlay.kind === "hover") {
      return `
        <div class="sb-hover ${state.overlay.focused ? "is-focused" : ""}" role="dialog" aria-label="Hover popover">
          <div class="sb-hover-head">
            <strong>classify_status/2 · Minga · 2m ago · change 1 of 2</strong>
            <span class="ml-dim">${state.overlay.focused ? "Focused (j/k scroll · y copy · q close)" : "Peek (press K again to focus)"}</span>
          </div>
          <p class="sb-hover-body"><code>@spec classify_status(pos_integer(), [{binary(), binary()}]) :: {:rate_limited, non_neg_integer()} | {:overloaded, non_neg_integer()} | {:fatal, pos_integer()}</code></p>
          <div class="sb-hover-foot">
            <button type="button" class="sb-inline-btn" data-sb-cmd="act">g. actions</button>
            <button type="button" class="sb-inline-btn" data-sb-cmd="dismiss-esc">esc close</button>
          </div>
        </div>`;
    }

    return "";
  }

  function renderCode(): string {
    const active = state.files.find((f) => f.id === state.activeFileId) ?? state.files[0];
    const gutterTop =
      state.changeStatus === "unreviewed"
        ? state.client === "tui"
          ? '<span class="ml-minga">▚</span>'
          : SVG_TWIST_CROSS
        : state.changeStatus === "kept"
          ? state.client === "tui"
            ? '<span class="ml-dim">│</span>'
            : SVG_TWIST_KEPT
          : "";
    const gutterMid =
      state.changeStatus === "unreviewed"
        ? state.client === "tui"
          ? '<span class="ml-minga">▐</span>'
          : SVG_TWIST_BODY
        : state.changeStatus === "kept"
          ? state.client === "tui"
            ? '<span class="ml-dim">│</span>'
            : SVG_TWIST_KEPT
          : "";
    const hl = state.changeStatus === "unreviewed" ? "spine-line-hl" : "";
    const rej = state.changeStatus === "rejected" ? "lab-line-rejected" : "";

    if (active && active.id !== "retry") {
      return `
        <div class="spine-line"><span class="spine-ln">1</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter"></span><span class="spine-code"><span class="ccm"># Viewing ${esc(active.name)} (${esc(active.dir)})</span></span></div>
        <div class="spine-line"><span class="spine-ln">2</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter"></span><span class="spine-code"><span class="ckw">defmodule</span> <span class="cat">Minga.Demo</span> <span class="ckw">do</span></span></div>
        <div class="spine-line"><span class="spine-ln">3</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter"></span><span class="spine-code">  <span class="ccm"># Press SPC , to switch back to retry.ex</span></span></div>
        <div class="spine-line"><span class="spine-ln">4</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter"></span><span class="spine-code"><span class="ckw">end</span></span></div>`;
    }

    return `
      <div class="spine-line" data-sb-ctx><span class="spine-ln">237</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter"></span><span class="spine-code"><span class="ckw">def</span> classify_status(status, headers) <span class="ckw">do</span></span></div>
      <div class="spine-line ${hl} ${rej} lab-cursor" data-sb-ctx><span class="spine-ln">238</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter">${gutterTop}</span><span class="spine-code">  <span class="ckw">case</span> status <span class="ckw">do</span></span></div>
      <div class="spine-line ${hl} ${rej}" data-sb-ctx><span class="spine-ln">239</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter">${gutterMid}</span><span class="spine-code">    <span class="cnum">429</span> -&gt; {<span class="cat">:rate_limited</span>, parse_retry_after(headers)}</span></div>
      <div class="spine-line ${hl} ${rej}" data-sb-ctx><span class="spine-ln">240</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter">${gutterMid}</span><span class="spine-code">    <span class="cnum">529</span> -&gt; {<span class="cat">:overloaded</span>, backoff_ms(<span class="cnum">2</span>)}</span></div>
      <div class="spine-line ${hl} ${rej}" data-sb-ctx><span class="spine-ln">241</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter">${gutterMid}</span><span class="spine-code">    code <span class="ckw">when</span> code &gt;= <span class="cnum">500</span> -&gt; {<span class="cat">:retryable</span>, backoff_ms(<span class="cnum">1</span>)}</span></div>
      <div class="spine-line" data-sb-ctx><span class="spine-ln">242</span><span class="spine-sign"></span><span class="spine-gutter" data-surface="gutter"></span><span class="spine-code">    _ -&gt; {<span class="cat">:fatal</span>, status}</span></div>`;
  }

  function render(): void {
    const active = state.files.find((f) => f.id === state.activeFileId) ?? state.files[0];
    const doneCount = state.completed.size;
    const pinnedCount = state.files.filter((f) => f.pinned).length;
    const modeLabel = state.profile === "cua" ? "CUA" : "NORMAL";

    const missionsHtml = SANDBOX_MISSIONS.map((m) => {
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

    const titlebar =
      state.client === "tui"
        ? `<div class="sb-tui-chrome"><span>┌─ minga · ${esc(active?.name ?? "retry.ex")}</span><span>Go Terminal UI · Lip Gloss ─┐</span></div>`
        : `<div class="spine-titlebar"><span class="spine-wordmark">minga</span><span class="spine-title-file">${esc(active?.name ?? "retry.ex")} <span>${esc(active?.dir ?? "")}</span></span><span></span></div>`;

    root.innerHTML = `
      <div class="workbench-shell">
        <div class="workbench-main">
          <div class="workbench-controls">
            <div class="seg-group" role="group" aria-label="Client surface">
              <button type="button" class="seg-btn ${state.client === "macos" ? "is-active" : ""}" data-sb-client="macos">macOS Native</button>
              <button type="button" class="seg-btn ${state.client === "tui" ? "is-active" : ""}" data-sb-client="tui">Go Terminal UI</button>
            </div>
            <div class="seg-group" role="group" aria-label="Input profile">
              <button type="button" class="seg-btn ${state.profile === "vim" ? "is-active" : ""}" data-sb-profile="vim">Vim</button>
              <button type="button" class="seg-btn ${state.profile === "cua" ? "is-active" : ""}" data-sb-profile="cua">CUA</button>
              <button type="button" class="seg-btn ${state.profile === "mouse" ? "is-active" : ""}" data-sb-profile="mouse">Mouse</button>
            </div>
            <button type="button" class="seg-btn seg-btn-reset" data-sb-cmd="reset">Reset</button>
          </div>

          <div class="lab-toolbar sb-quickbar" role="toolbar" aria-label="Trigger Minga keys">
            <button type="button" class="lab-cmd" data-sb-cmd="whichkey"><span>SPC</span> Which-key</button>
            <button type="button" class="lab-cmd" data-sb-cmd="switcher"><span>SPC ,</span> Switcher</button>
            <button type="button" class="lab-cmd" data-sb-cmd="act"><span>g.</span> Act menu</button>
            <button type="button" class="lab-cmd" data-sb-cmd="hover"><span>K</span> Hover</button>
            <button type="button" class="lab-cmd" data-sb-cmd="dismiss-q"><span>q</span> Close</button>
          </div>

          <div class="spine-specimen sb-viewport ${state.client === "tui" ? "is-tui" : ""}" tabindex="0" data-sb-stage aria-label="Playable Mini-Minga viewport. Focus and type Space, SPC ,, g., K, q, or Escape.">
            ${titlebar}
            <div class="sb-stage-body">
              <div class="spine-buffer">${renderCode()}</div>
              ${renderOverlay()}
            </div>
            <div class="spine-modeline">
              <div class="ml-left">
                <button type="button" class="ml-pill ml-clickable" data-sb-cmd="whichkey" title="Click mode pill to open which-key">${modeLabel}</button>
                <button type="button" class="ml-seg ml-file ml-clickable" data-sb-cmd="switcher" title="Click filename to open switcher">${esc(active?.name ?? "retry.ex")}</button>
                ${state.changeStatus === "unreviewed" && active?.id === "retry" ? '<button type="button" class="ml-seg ml-minga ml-clickable" data-sb-cmd="act">change 1/2</button>' : ""}
                <span class="ml-dim">pinned ${pinnedCount}</span>
              </div>
              <div class="ml-right">
                <span class="ml-dim">${state.pendingPrefix ? `prefix ${state.pendingPrefix}...` : "elixir · 238:3"}</span>
              </div>
            </div>
            <div class="sb-echo">${esc(state.echoNotice)}</div>
          </div>

          <div class="lab-note">${esc(state.lastAction)}</div>
        </div>

        <aside class="workbench-missions" aria-label="Interactive missions">
          <div class="missions-head">
            <span>MISSIONS</span>
            <span>${doneCount} / ${SANDBOX_MISSIONS.length}</span>
          </div>
          <p class="missions-sub">Focus the viewport and press real keys (or tap the toolbar and clickable modeline segments) to complete each mission.</p>
          <ul class="mission-list">${missionsHtml}</ul>
        </aside>
      </div>`;
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;

    const clientBtn = target.closest<HTMLElement>("[data-sb-client]");
    if (clientBtn) {
      const c = clientBtn.getAttribute("data-sb-client");
      if (c === "macos" || c === "tui") update(setSandboxClient(state, c));
      return;
    }

    const profileBtn = target.closest<HTMLElement>("[data-sb-profile]");
    if (profileBtn) {
      const p = profileBtn.getAttribute("data-sb-profile");
      if (p === "vim" || p === "cua" || p === "mouse") update(setSandboxProfile(state, p));
      return;
    }

    const pinBtn = target.closest<HTMLElement>("[data-sb-pin]");
    if (pinBtn) {
      event.stopPropagation();
      const idx = Number(pinBtn.getAttribute("data-sb-pin"));
      update(togglePinSelected(state, idx));
      return;
    }

    const openRow = target.closest<HTMLElement>("[data-sb-open]");
    if (openRow) {
      const idx = Number(openRow.getAttribute("data-sb-open"));
      const withSel: SandboxState = { ...state, overlay: { kind: "switcher", selectedIndex: idx } };
      update(handleSandboxKey(withSel, { key: "Enter" }));
      return;
    }

    const cmdBtn = target.closest<HTMLElement>("[data-sb-cmd]");
    if (cmdBtn) {
      const cmd = cmdBtn.getAttribute("data-sb-cmd");
      if (cmd === "whichkey") update(openWhichKey(state, "SPC"));
      else if (cmd === "wk-a") update(openWhichKey(state, "SPC a"));
      else if (cmd === "switcher") update(openSwitcher(state));
      else if (cmd === "act") update(openActMenu(state, "key"));
      else if (cmd === "hover") update(openHover(state));
      else if (cmd === "keep") update(resolveActDecision(state, "keep"));
      else if (cmd === "reject") update(resolveActDecision(state, "reject"));
      else if (cmd === "dismiss-q") update(dismissOverlay(state, "q"));
      else if (cmd === "dismiss-esc") update(dismissOverlay(state, "esc"));
      else if (cmd === "reset") update(createSandboxState(state.completed));
    }
  });

  root.addEventListener("contextmenu", (event) => {
    const target = event.target as HTMLElement | null;
    if (target?.closest("[data-sb-ctx]")) {
      event.preventDefault();
      update(openActMenu(state, "mouse"));
    }
  });

  root.addEventListener("keydown", (event) => {
    const stage = (event.target as HTMLElement | null)?.closest("[data-sb-stage]");
    if (!stage) return;
    if ([" ", "ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight", "Escape", "Enter"].includes(event.key) || (event.ctrlKey && ["j", "k", "t", "."].includes(event.key.toLowerCase()))) {
      event.preventDefault();
    }
    const next = handleSandboxKey(state, {
      key: event.key,
      ctrl: event.ctrlKey,
      meta: event.metaKey,
      alt: event.altKey,
    });
    if (next !== state) {
      update(next);
      root.querySelector<HTMLElement>("[data-sb-stage]")?.focus();
    }
  });

  render();
}
