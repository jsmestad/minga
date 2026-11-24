/* Lesson 05: Interactive Headless Devbox, MCP Fault-Injection & PreToolUse Veto Lab. */

import { completeMission, getCompletedMissions } from "./progress.ts";

export interface PreToolUseResult {
  readonly allowed: boolean;
  readonly exitCode: 0 | 1;
  readonly stdinJson: string;
  readonly stderr: string;
  readonly summary: string;
}

const BLOCKED_PATTERNS: readonly { readonly re: RegExp; readonly reason: string }[] = [
  { re: /git\s+push\b.*(--force|-f\b)/i, reason: "Force push is blocked by local PreToolUse safety hook." },
  { re: /rm\s+-rf\s+(\/|~|\$HOME|\*)/i, reason: "Recursive delete targeting root or broad path is blocked." },
  { re: /\b(drop\s+table|truncate\s+table)\b/i, reason: "Destructive SQL DDL is blocked outside migration scripts." },
];

export function evaluatePreToolUse(command: string): PreToolUseResult {
  const trimmed = command.trim();
  const stdinJson = JSON.stringify({ event: "PreToolUse", tool: "shell", command: trimmed }, null, 2);
  for (const rule of BLOCKED_PATTERNS) {
    if (rule.re.test(trimmed)) {
      return {
        allowed: false,
        exitCode: 1,
        stdinJson,
        stderr: `Blocked by local safety hook: ${rule.reason}`,
        summary: "Hook exited 1 -> tool call vetoed before execution; stderr surfaced in chat.",
      };
    }
  }
  return {
    allowed: true,
    exitCode: 0,
    stdinJson,
    stderr: "",
    summary: "Hook exited 0 -> tool proceeds to normal user approval (y / a / t / n).",
  };
}

export type RemoteMissionId = "detach_reattach" | "mcp_crash" | "pretooluse_veto";

const REMOTE_MISSIONS: readonly { readonly id: RemoteMissionId; readonly label: string; readonly hint: string }[] = [
  { id: "detach_reattach", label: "Survive laptop sleep", hint: "Close laptop lid, then Reattach via SSH" },
  { id: "mcp_crash", label: "Contain an MCP crash", hint: "Crash GitHub MCP and inspect healthy nodes" },
  { id: "pretooluse_veto", label: "Trigger a PreToolUse veto", hint: "Run git push --force through the hook" },
];

function esc(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

export function mountRemoteLab(root: HTMLElement): void {
  const completed = new Set(Array.from(getCompletedMissions("remote")) as RemoteMissionId[]);
  let attached = true;
  let detachedSteps = 0;
  let githubMcpUp = true;
  let commandInput = "git push --force origin main";
  let lastHook = evaluatePreToolUse(commandInput);
  let lastEvent = "Connected to remote Linux devbox over Erlang distribution. Every service runs in its own supervised BEAM process.";
  let stepTimer: number | undefined;

  function mark(m: RemoteMissionId): void {
    if (!completed.has(m)) {
      completed.add(m);
      completeMission("remote", m);
    }
  }

  function render(): void {
    const missionsHtml = REMOTE_MISSIONS.map((m) => {
      const done = completed.has(m.id);
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
          <div class="lab-toolbar" role="toolbar" aria-label="Fault-injection controls">
            <button type="button" class="lab-cmd" data-rm-action="toggle-lid">
              <span>${attached ? "SSH" : "ATTACH"}</span> ${attached ? "Close laptop lid (detach)" : "minga attach ssh://devbox"}
            </button>
            <button type="button" class="lab-cmd" data-rm-action="toggle-mcp">
              <span>${githubMcpUp ? "FAULT" : "HEAL"}</span> ${githubMcpUp ? "Crash GitHub MCP" : "Restart GitHub MCP"}
            </button>
            <button type="button" class="lab-cmd lab-cmd-muted" data-rm-action="reset">Reset</button>
          </div>

          <div class="topo-canvas">
            <div class="topo-zone ${attached ? "is-ok" : "is-detached"}">
              <div class="topo-zone-head">
                <strong>YOUR LAPTOP</strong>
                <span class="topo-pill ${attached ? "is-ok" : "is-warn"}">${attached ? "Attached" : "Lid closed · Sleeping"}</span>
              </div>
              <div class="topo-node">
                <strong>macOS App / Go TUI</strong>
                <span>${attached ? "Streaming UI tokens over ssh://devbox" : "Disconnected cleanly; zero source files stored locally"}</span>
              </div>
            </div>

            <div class="topo-link ${attached ? "is-ok" : "is-detached"}" aria-hidden="true">
              ${attached ? "<-- SSH / Erlang Dist -->" : "x-- detached --x"}
            </div>

            <div class="topo-zone is-ok">
              <div class="topo-zone-head">
                <strong>LINUX DEVBOX · minga --headless</strong>
                <span class="topo-pill is-ok">systemd linger · Alive</span>
              </div>
              <div class="topo-nodes">
                <div class="topo-node is-ok">
                  <strong>Open Buffers &amp; Undo</strong>
                  <span>Isolated per-file heaps · Intact</span>
                </div>
                <div class="topo-node is-ok">
                  <strong>Agent Session &amp; Logs</strong>
                  <span>${detachedSteps > 0 ? `Completed ${detachedSteps} ${detachedSteps === 1 ? "step" : "steps"} while offline · logs retained` : "Working · shell logs persisted past 51 KiB preview"}</span>
                </div>
                <div class="topo-node ${githubMcpUp ? "is-ok" : "is-fail"}">
                  <strong>GitHub MCP (stdio)</strong>
                  <span>${githubMcpUp ? "Healthy · mcp_github__* available" : "Crashed · only mcp_github__* dropped out"}</span>
                </div>
                <div class="topo-node is-ok">
                  <strong>Postgres MCP + Built-in Tools</strong>
                  <span>Unaffected · still serving queries &amp; file tools</span>
                </div>
              </div>
            </div>
          </div>

          <div class="veto-panel">
            <div class="veto-head">
              <strong>PreToolUse SHELL VETO TESTER</strong>
              <span class="topo-pill ${lastHook.allowed ? "is-ok" : "is-fail"}">exit ${lastHook.exitCode} · ${lastHook.allowed ? "ALLOWED" : "VETOED"}</span>
            </div>
            <div class="veto-presets">
              <button type="button" class="lab-cmd" data-rm-cmd="git push --force origin main"><span>Veto</span> git push --force</button>
              <button type="button" class="lab-cmd" data-rm-cmd="rm -rf /tmp/prod"><span>Veto</span> rm -rf /</button>
              <button type="button" class="lab-cmd" data-rm-cmd="mix test test/minga_agent/retry_test.exs"><span>Allow</span> mix test</button>
            </div>
            <div class="veto-input-row">
              <label class="sr-only" for="rm-cmd-input">Shell command to test against PreToolUse hook</label>
              <input id="rm-cmd-input" class="veto-input" type="text" value="${esc(commandInput)}" data-rm-input>
              <button type="button" class="btn" data-rm-action="run-hook">Run hook</button>
            </div>
            <div class="veto-io">
              <div>
                <span class="veto-io-label">stdin -&gt; check-shell-command.sh</span>
                <pre><code>${esc(lastHook.stdinJson)}</code></pre>
              </div>
              <div>
                <span class="veto-io-label">result (exit ${lastHook.exitCode})</span>
                <p class="veto-result ${lastHook.allowed ? "is-ok" : "is-fail"}">${esc(lastHook.stderr || lastHook.summary)}</p>
                ${lastHook.stderr ? `<p class="veto-sub">${esc(lastHook.summary)}</p>` : ""}
              </div>
            </div>
          </div>

          <div class="lab-note" aria-live="polite">${esc(lastEvent)}</div>
        </div>

        <aside class="workbench-missions" aria-label="Remote & safety missions">
          <div class="missions-head">
            <span>MISSIONS</span>
            <span>${completed.size} / ${REMOTE_MISSIONS.length}</span>
          </div>
          <p class="missions-sub">Inject faults directly into the supervision topology and test the PreToolUse shell guardrail.</p>
          <ul class="mission-list">${missionsHtml}</ul>
        </aside>
      </div>`;
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;

    const cmdBtn = target.closest<HTMLElement>("[data-rm-cmd]");
    if (cmdBtn) {
      commandInput = cmdBtn.getAttribute("data-rm-cmd") ?? commandInput;
      lastHook = evaluatePreToolUse(commandInput);
      if (!lastHook.allowed) mark("pretooluse_veto");
      lastEvent = lastHook.summary;
      render();
      return;
    }

    const actBtn = target.closest<HTMLElement>("[data-rm-action]");
    if (!actBtn) return;
    const action = actBtn.getAttribute("data-rm-action");

    if (action === "toggle-lid") {
      if (attached) {
        attached = false;
        detachedSteps = 1;
        lastEvent = "Laptop lid closed: client detached, remote minga --headless kept working and retaining logs. Click Reattach.";
        if (stepTimer !== undefined) window.clearInterval(stepTimer);
        stepTimer = window.setInterval(() => {
          if (!attached && detachedSteps < 4) {
            detachedSteps += 1;
            render();
          }
        }, 1200);
      } else {
        attached = true;
        if (stepTimer !== undefined) window.clearInterval(stepTimer);
        mark("detach_reattach");
        lastEvent = `Reattached via minga attach ssh://devbox: caught up on ${detachedSteps} background steps with zero lost output.`;
      }
      render();
    } else if (action === "toggle-mcp") {
      githubMcpUp = !githubMcpUp;
      if (!githubMcpUp) {
        mark("mcp_crash");
        lastEvent = "GitHub MCP process crashed: supervisor isolated the failure so open buffers, undo, Postgres MCP, and built-in tools stayed green.";
      } else {
        lastEvent = "Supervisor restarted GitHub MCP cleanly; mcp_github__* tools are back online.";
      }
      render();
    } else if (action === "run-hook") {
      const inputEl = root.querySelector<HTMLInputElement>("[data-rm-input]");
      commandInput = inputEl?.value ?? commandInput;
      lastHook = evaluatePreToolUse(commandInput);
      if (!lastHook.allowed) mark("pretooluse_veto");
      lastEvent = lastHook.summary;
      render();
    } else if (action === "reset") {
      attached = true;
      detachedSteps = 0;
      githubMcpUp = true;
      if (stepTimer !== undefined) window.clearInterval(stepTimer);
      commandInput = "git push --force origin main";
      lastHook = evaluatePreToolUse(commandInput);
      lastEvent = "Topology reset: all supervised services healthy.";
      render();
    }
  });

  render();
}
