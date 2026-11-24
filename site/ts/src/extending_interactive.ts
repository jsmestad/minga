/* Extending Minga interactive explorer: 3-Layer Graduation Ladder with Elixir syntax highlighting. */

import { highlightElixirBlock } from "./highlight.ts";

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
    label: "Format on save",
    layers: {
      1: {
        badge: "Live reload (SPC h r)",
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
        badge: "Supervised Hex/Git package",
        filename: "lib/my_fmt_extension.ex (minga_sdk)",
        reloadRule: "Clean VM generation on restart (ADR-0003)",
        isolation: "Tagged ownership; disabling unregisters every command",
        code: `defmodule MyFmtExtension do
  use Minga.Extension.Editor

  option :gofmt_flags, :list, default: ["-s", "-w"]
  command :format_workspace, "Format Go files",
    execute: {__MODULE__, :run}
  keybind :normal, "SPC m f", :format_workspace,
    "Format workspace", filetype: :go
end`,
      },
      3: {
        badge: "Coming · v0.1.0 task workflow",
        filename: "workflows/pr_lint_board.exs",
        reloadRule: "Save to activate under explicit revocable session grant",
        isolation: "Restores last working generation if a candidate fails",
        code: `# Disposable v0.1.0 workflow over real buffer + drawer owners
workflow :pr_lint_board do
  grant [:buffers_read, :drawer_register]
  drawer "*lint-summary*", title: "PR Formatter & Lint"
  on :after_save, &refresh_changed_files/2
end`,
      },
    },
  },
  veto: {
    id: "veto",
    label: "Shell veto",
    layers: {
      1: {
        badge: "Deterministic PreToolUse",
        filename: "~/.config/minga/config.exs",
        reloadRule: "Live reload via SPC h r; active on next tool call",
        isolation: "POSIX process-group timeout; non-zero exit blocks execution",
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
        badge: "Team policy extension",
        filename: "lib/corp_guardrails.ex (minga_sdk)",
        reloadRule: "Distributed via private Git/Hex; version-pinned",
        isolation: "Dedicated supervisor + structured audit log per veto",
        code: `defmodule CorpGuardrails do
  use Minga.Extension.Editor

  option :blocked_patterns, :list,
    default: ["git push --force", "terraform destroy"]
  command :audit_blocked, "Show veto audit log",
    execute: {__MODULE__, :show_log}
end`,
      },
      3: {
        badge: "Coming · v0.1.0 task workflow",
        filename: "workflows/prod_change_gate.exs",
        reloadRule: "Scoped to one release window; discard when done",
        isolation: "Explicit diff review before activating in session",
        code: `# One-off release guardrail for a high-risk deploy window
workflow :prod_change_gate do
  grant [:agent_approval_hook, :drawer_register]
  require_reason_for ["kubectl", "terraform", "psql"]
end`,
      },
    },
  },
  gateway: {
    id: "gateway",
    label: "LLM proxy & MCP",
    layers: {
      1: {
        badge: "Crash-isolated stdio MCP",
        filename: "~/.config/minga/config.exs",
        reloadRule: "Live reload via SPC h r; tools prefixed mcp_<server>__*",
        isolation: "If one MCP exits mid-turn, only its tools drop out",
        code: `set :agent_mcp_servers, [
  %{name: "github", command: "npx",
    args: ["-y", "@modelcontextprotocol/server-github"]},
  %{name: "postgres", command: "uvx",
    args: ["mcp-server-postgres"]}
]`,
      },
      2: {
        badge: "Custom InferenceRoute",
        filename: "lib/acme_llm_route.ex (minga_sdk)",
        reloadRule: "Plugged into /model; Minga still owns approvals & overlays",
        isolation: "Zero public API calls; traffic stays on internal proxy",
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
        code: `# Reusable workflow pairing gateway metrics with a drawer
workflow :cost_budget_hud do
  grant [:agent_usage_read, :drawer_register]
  warn_above_tokens 120_000
end`,
      },
    },
  },
  migration: {
    id: "migration",
    label: "SQL migration",
    layers: {
      1: {
        badge: "Filetype rules & advice",
        filename: "~/.config/minga/config.exs",
        reloadRule: "Live reload via SPC h r",
        isolation: "Buffer-local options + isolated command wrapper",
        code: `for_filetype :sql, tab_width: 2, line_numbers: :absolute

advise :before, :save, fn state ->
  Minga.API.message("Check lock timeout before migration")
  state
end`,
      },
      2: {
        badge: "Supervised migration checker",
        filename: "lib/sql_safety_ext.ex (minga_sdk)",
        reloadRule: "Install once via Hex/Git; lazy load on :sql_check",
        isolation: "Zero startup cost via {:on_command, [:sql_check]}",
        code: `extension :sql_safety_ext,
  git: "https://github.com/acme/sql_safety_ext",
  load_policy: {:on_command, [:sql_check]}`,
      },
      3: {
        badge: "Coming · v0.1.0 disposable workflow",
        filename: "workflows/tuesday_migration_audit.exs",
        reloadRule: "Author for Tuesday's PR, discard Wednesday (or reuse)",
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
          `<button type="button" class="le-sc-btn ${id === scenario ? "is-active" : ""}" data-le-sc="${id}">${EXTENDING_SCENARIOS[id].label}</button>`,
      )
      .join("");

    const layerBtns: readonly { readonly n: LayerNum; readonly title: string; readonly sub: string }[] = [
      { n: 1, title: "Layer 1 · config.exs", sub: "Live reload" },
      { n: 2, title: "Layer 2 · minga_sdk", sub: "Hex / Git packages" },
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
          <span>PICK A REAL TASK &amp; WATCH IT GRADUATE ACROSS LAYERS</span>
        </div>
        <div class="le-scenarios" role="group" aria-label="Choose customization scenario">${scBtns}</div>
        <div class="le-layers" role="group" aria-label="Choose extension layer">${tabsHtml}</div>
        <div class="le-body">
          <div class="le-meta">
            <div><span class="lens-k">STATUS</span><strong>${esc(spec.badge)}</strong></div>
            <div><span class="lens-k">RELOAD BOUNDARY</span><strong>${esc(spec.reloadRule)}</strong></div>
            <div><span class="lens-k">FAILURE ISOLATION</span><strong>${esc(spec.isolation)}</strong></div>
          </div>
          <div class="code-card le-code is-frappe">
            <div class="code-header">
              <span>${esc(spec.filename)}</span>
              <span>Elixir · Layer ${layer}</span>
            </div>
            <pre><code>${highlightElixirBlock(spec.code)}</code></pre>
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
