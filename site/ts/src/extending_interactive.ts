/* Extending Minga interactive demos: 3-Layer Graduation Explorer + Layer 3 Save-to-Activate & Rollback Safety Demo. */

export type ScenarioId = "format" | "veto" | "gateway" | "migration";
export type LayerNum = 1 | 2 | 3;

export interface LayerSpec {
  readonly badge: string;
  readonly filename: string;
  readonly reloadRule: string;
  readonly isolation: string;
  readonly code: string;
}

export interface ScenarioSpec {
  readonly id: ScenarioId;
  readonly label: string;
  readonly layers: Record<LayerNum, LayerSpec>;
}

export const EXTENDING_SCENARIOS: Record<ScenarioId, ScenarioSpec> = {
  format: {
    id: "format",
    label: "Format & lint on save",
    layers: {
      1: {
        badge: "Ships today · Live reload (SPC h r)",
        filename: "~/.config/minga/config.exs",
        reloadRule: "Live reload via SPC h r; no restart needed",
        isolation: "Runs in async background BEAM Task; typing never stalls",
        code: `on :after_save, fn _buf, path ->
  if String.ends_with?(path, ".go") do
    System.cmd("gofmt", ["-w", path])
  end
end`,
      },
      2: {
        badge: "Ships today · Supervised Hex/Git package",
        filename: "lib/my_fmt_extension.ex (minga_sdk)",
        reloadRule: "Clean VM generation on restart (ADR-0003)",
        isolation: "Tagged ownership; disabling unregisters every command and keybind",
        code: `defmodule MyFmtExtension do
  use Minga.Extension.Editor

  option :gofmt_flags, :list, default: ["-s", "-w"]
  command :format_workspace, "Format all Go files", execute: {__MODULE__, :run}
  keybind :normal, "SPC m f", :format_workspace, "Format workspace", filetype: :go
end`,
      },
      3: {
        badge: "Coming · v0.1.0 task workflow",
        filename: "workflows/pr_lint_board.exs",
        reloadRule: "Save to activate under explicit revocable session grant",
        isolation: "Automatic restore to last working generation if candidate fails",
        code: `# Disposable v0.1.0 workflow over real buffer + drawer primitives
workflow :pr_lint_board do
  grant [:buffers_read, :drawer_register]
  drawer "*lint-summary*", title: "PR Formatter & Lint Check"
  on :after_save, &refresh_changed_files/2
end`,
      },
    },
  },
  veto: {
    id: "veto",
    label: "Block risky shell commands",
    layers: {
      1: {
        badge: "Ships today · Deterministic PreToolUse",
        filename: "~/.config/minga/config.exs",
        reloadRule: "Live reload via SPC h r; active on next tool call",
        isolation: "POSIX process-group timeout; non-zero exit vetoes execution",
        code: `set :agent_hooks, [
  %{
    event: "PreToolUse",
    matcher: "shell",
    command: "~/.config/minga/hooks/block_destructive.sh",
    timeout: 5_000
  }
]`,
      },
      2: {
        badge: "Ships today · Team policy extension",
        filename: "lib/corp_guardrails.ex (minga_sdk)",
        reloadRule: "Distributed via private Git/Hex; version-pinned",
        isolation: "Dedicated supervisor + structured audit log per blocked call",
        code: `defmodule CorpGuardrails do
  use Minga.Extension.Editor

  option :blocked_patterns, :list, default: ["git push --force", "terraform destroy"]
  command :audit_blocked, "Show veto audit log", execute: {__MODULE__, :show_log}
end`,
      },
      3: {
        badge: "Coming · v0.1.0 task workflow",
        filename: "workflows/prod_change_gate.exs",
        reloadRule: "Scoped to one incident or release window; discard when done",
        isolation: "Explicit human review of workflow source diff before activation",
        code: `# One-off release guardrail authored for a high-risk deploy window
workflow :prod_change_gate do
  grant [:agent_approval_hook, :drawer_register]
  require_reason_for ~w(kubectl terraform psql)
end`,
      },
    },
  },
  gateway: {
    id: "gateway",
    label: "Corporate LLM proxy & MCP",
    layers: {
      1: {
        badge: "Ships today · Crash-isolated stdio MCP",
        filename: "~/.config/minga/config.exs",
        reloadRule: "Live reload via SPC h r; tools prefixed mcp_<server>__*",
        isolation: "If one MCP exits mid-turn, only its tools drop out",
        code: `set :agent_mcp_servers, [
  %{name: "github", command: "npx", args: ["-y", "@modelcontextprotocol/server-github"]},
  %{name: "postgres", command: "uvx", args: ["mcp-server-postgres"]}
]`,
      },
      2: {
        badge: "Ships today · Custom InferenceRoute",
        filename: "lib/acme_llm_route.ex (minga_sdk)",
        reloadRule: "Plugged into /model; Minga still owns approvals & overlays",
        isolation: "Zero public API calls; traffic stays on corporate proxy",
        code: `defmodule AcmeLLMRoute do
  @behaviour MingaAgent.InferenceRoute

  @impl true
  def stream(request, opts) do
    AcmeProxy.stream_chat(request.messages, model: opts[:model])
  end
end`,
      },
      3: {
        badge: "Coming · v0.1.0 task workflow",
        filename: "workflows/cost_budget_hud.exs",
        reloadRule: "Save to activate; reusable across repos if it sticks",
        isolation: "Reads canonical agent session usage without shadow state",
        code: `# Reusable team workflow pairing corporate gateway metrics with a drawer
workflow :cost_budget_hud do
  grant [:agent_usage_read, :drawer_register]
  warn_above_tokens 120_000
end`,
      },
    },
  },
  migration: {
    id: "migration",
    label: "Audit a risky SQL migration",
    layers: {
      1: {
        badge: "Ships today · Filetype rules & keybind",
        filename: "~/.config/minga/config.exs",
        reloadRule: "Live reload via SPC h r",
        isolation: "Buffer-local options + command wrapper",
        code: `for_filetype :sql, tab_width: 2, line_numbers: :absolute

advise :before, :save, fn state ->
  Minga.API.message("Check lock timeout before running migration")
  state
end`,
      },
      2: {
        badge: "Ships today · Supervised migration checker",
        filename: "lib/sql_safety_ext.ex (minga_sdk)",
        reloadRule: "Install once via Hex/Git; lazy load on :sql_check",
        isolation: "Zero startup cost with load_policy: {:on_command, [:sql_check]}",
        code: `extension :sql_safety_ext,
  git: "https://github.com/acme/sql_safety_ext",
  load_policy: {:on_command, [:sql_check]}`,
      },
      3: {
        badge: "Coming · v0.1.0 disposable workflow",
        filename: "workflows/tuesday_migration_audit.exs",
        reloadRule: "Author for Tuesday's PR, discard Wednesday (or save to reuse)",
        isolation: "Runs identically on macOS Metal and Go Terminal UI",
        code: `# Disposable v0.1.0 workflow (ADR-0004)
workflow :tuesday_migration_audit do
  grant [:buffers_read, :drawer_register]
  drawer "*migration-checks*",
    columns: [:table, :lock_risk, :status]
  action "Send Revision", key: "SPC m r"
end`,
      },
    },
  },
};

export type RollbackStage = "draft" | "granted" | "active" | "rolled_back" | "discarded";

export interface RollbackDemoState {
  readonly stage: RollbackStage;
  readonly activeGeneration: number;
  readonly grantActive: boolean;
  readonly statusLine: string;
  readonly errorDetail: string;
}

export function createRollbackDemoState(): RollbackDemoState {
  return {
    stage: "draft",
    activeGeneration: 1,
    grantActive: false,
    statusLine: "Reviewing readable Elixir source diff before any code runs.",
    errorDetail: "",
  };
}

export type RollbackAction = "grant" | "activate" | "inject_failure" | "discard" | "reset";

export function reduceRollbackDemo(state: RollbackDemoState, action: RollbackAction): RollbackDemoState {
  switch (action) {
    case "grant":
      return {
        ...state,
        stage: "granted",
        grantActive: true,
        errorDetail: "",
        statusLine: "Explicit revocable session grant approved (buffers: read, drawer: register). Ready to save & activate.",
      };
    case "activate":
      if (!state.grantActive) {
        return {
          ...state,
          errorDetail: "Blocked: activation requires an explicit revocable session grant first (step 1).",
        };
      }
      return {
        ...state,
        stage: "active",
        activeGeneration: 2,
        errorDetail: "",
        statusLine: "Generation #2 active identically on macOS and Go Terminal UI. Drawer *migration-checks* live.",
      };
    case "inject_failure":
      if (state.stage !== "active" && state.stage !== "rolled_back") {
        return {
          ...state,
          errorDetail: "Activate Generation #2 first so there is a live generation to restore on failure.",
        };
      }
      return {
        ...state,
        stage: "rolled_back",
        activeGeneration: 2,
        errorDetail: "Candidate Generation #3 failed admission (CompileError on line 14: undefined function lock_timeout/0). Automatically restored Generation #2.",
        statusLine: "Automatic restore succeeded: Generation #2 stayed live, 0 buffers lost, editor never crashed.",
      };
    case "discard":
      return {
        ...state,
        stage: "discarded",
        activeGeneration: 1,
        grantActive: false,
        errorDetail: "",
        statusLine: "PR landed: workflow discarded cleanly, grant revoked, 0 lingering commands or keybindings.",
      };
    case "reset":
      return createRollbackDemoState();
  }
}

function esc(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function mountLayerExplorer(root: HTMLElement): void {
  let scenario: ScenarioId = "format";
  let layer: LayerNum = 1;

  function render(): void {
    const sc = EXTENDING_SCENARIOS[scenario];
    const spec = sc.layers[layer];

    const scBtns = (Object.keys(EXTENDING_SCENARIOS) as ScenarioId[])
      .map(
        (id) =>
          `<button type="button" class="seg-btn ${id === scenario ? "is-active" : ""}" data-le-sc="${id}">${EXTENDING_SCENARIOS[id].label}</button>`,
      )
      .join("");

    const layerBtns: readonly { readonly n: LayerNum; readonly title: string; readonly sub: string }[] = [
      { n: 1, title: "Layer 1 · config.exs", sub: "Ships today" },
      { n: 2, title: "Layer 2 · minga_sdk", sub: "Ships today" },
      { n: 3, title: "Layer 3 · Task workflow", sub: "Coming · v0.1.0" },
    ];

    const tabsHtml = layerBtns
      .map(
        (b) => `
          <button type="button" class="le-layer-btn ${layer === b.n ? "is-active" : ""}" data-le-layer="${b.n}">
            <strong>${b.title}</strong>
            <span>${b.sub}</span>
          </button>`,
      )
      .join("");

    root.innerHTML = `
      <div class="story-box">
        <div class="story-bar">
          <span>INTERACTIVE LADDER · PICK A REAL TASK &amp; WATCH IT GRADUATE</span>
          <div class="seg-group" role="group" aria-label="Choose customization scenario">${scBtns}</div>
        </div>
        <div class="le-layers" role="group" aria-label="Choose extension layer">${tabsHtml}</div>
        <div class="le-body">
          <div class="le-meta">
            <div><span class="lens-k">STATUS</span><strong>${esc(spec.badge)}</strong></div>
            <div><span class="lens-k">RELOAD BOUNDARY</span><strong>${esc(spec.reloadRule)}</strong></div>
            <div><span class="lens-k">FAILURE ISOLATION</span><strong>${esc(spec.isolation)}</strong></div>
          </div>
          <div class="code-card le-code">
            <div class="code-header">
              <span>${esc(spec.filename)}</span>
              <span>Elixir · Layer ${layer}</span>
            </div>
            <pre><code>${esc(spec.code)}</code></pre>
          </div>
        </div>
      </div>
    `;
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;

    const scBtn = target.closest<HTMLElement>("[data-le-sc]");
    if (scBtn) {
      const id = scBtn.getAttribute("data-le-sc") as ScenarioId | null;
      if (id && id in EXTENDING_SCENARIOS) {
        scenario = id;
        render();
      }
      return;
    }

    const lBtn = target.closest<HTMLElement>("[data-le-layer]");
    if (lBtn) {
      const n = Number(lBtn.getAttribute("data-le-layer"));
      if (n === 1 || n === 2 || n === 3) {
        layer = n;
        render();
      }
    }
  });

  render();
}

export function mountWorkflowRollbackDemo(root: HTMLElement): void {
  let state = createRollbackDemoState();

  function render(): void {
    const stagePill: Record<RollbackStage, { text: string; cls: string }> = {
      draft: { text: "DRAFT · UNACTIVATED", cls: "is-warn" },
      granted: { text: "GRANT APPROVED · READY", cls: "is-ok" },
      active: { text: "ACTIVE · GEN #2", cls: "is-ok" },
      rolled_back: { text: "RESTORED · GEN #2 SAFE", cls: "is-ok" },
      discarded: { text: "DISCARDED · 0 LEFTOVER", cls: "is-warn" },
    };
    const pill = stagePill[state.stage];

    root.innerHTML = `
      <div class="story-box">
        <div class="story-bar">
          <span>INTERACTIVE SAFETY LOOP · SAVE-TO-ACTIVATE &amp; AUTOMATIC ROLLBACK</span>
          <span class="topo-pill ${pill.cls}">${pill.text}</span>
        </div>
        <div class="rb-actions">
          <button type="button" class="lab-cmd ${state.stage === "draft" ? "is-next" : ""}" data-wr-act="grant"><span>1</span> Approve revocable grant</button>
          <button type="button" class="lab-cmd ${state.stage === "granted" ? "is-next" : ""}" data-wr-act="activate"><span>2</span> Save &amp; Activate Gen #2</button>
          <button type="button" class="lab-cmd ${state.stage === "active" ? "is-next" : ""}" data-wr-act="inject_failure"><span>3</span> Inject broken Gen #3</button>
          <button type="button" class="lab-cmd" data-wr-act="discard"><span>4</span> Discard after PR</button>
          <button type="button" class="lab-cmd lab-cmd-muted" data-wr-act="reset">Reset</button>
        </div>
        <div class="rb-panels">
          <div class="rb-card">
            <span class="lens-k">ACTIVE GENERATION</span>
            <strong>Generation #${state.activeGeneration}</strong>
            <p>${esc(state.statusLine)}</p>
          </div>
          <div class="rb-card">
            <span class="lens-k">SESSION PERMISSION GRANT</span>
            <strong>${state.grantActive ? "Active (revocable anytime)" : "None granted"}</strong>
            <p>${state.grantActive ? "Scoped strictly to buffers:read + drawer:register. Zero silent hot-patching." : "No workflow code executes until you review the diff and approve a session grant."}</p>
          </div>
        </div>
        ${state.errorDetail ? `<div class="rb-alert" aria-live="polite">${esc(state.errorDetail)}</div>` : ""}
      </div>
    `;
  }

  root.addEventListener("click", (event) => {
    const btn = (event.target as HTMLElement | null)?.closest<HTMLElement>("[data-wr-act]");
    if (!btn) return;
    const act = btn.getAttribute("data-wr-act") as RollbackAction | null;
    if (act === "grant" || act === "activate" || act === "inject_failure" || act === "discard" || act === "reset") {
      state = reduceRollbackDemo(state, act);
      render();
    }
  });

  render();
}
