defmodule Minga.Credo.EditorStateOwnership.Config do
  @moduledoc """
  Declarative ownership and purity-boundary configuration for EX9012.

  The scanner consumes this ledger but does not decide architectural policy.
  Owner additions and external boundary categories stay reviewable independently
  from AST traversal, validation, and issue formatting.
  """

  @typedoc "Declarative metadata for one protected value owner."
  @type ownership :: keyword()

  @typedoc "A fully resolved EX9012 scanner configuration."
  @type t :: %{
          ownerships: [ownership()],
          pure_modules: [String.t()] | :owners,
          allowlist: []
        }

  @ownerships [
    [
      struct: "MingaEditor.State.FileTree.Refresh",
      owners: ["MingaEditor.State.FileTree.Refresh"],
      paths: [[:file_tree, :refresh]],
      boundary: "MingaEditor.State.FileTree.Refresh transition API",
      workflow: "MingaEditor.FileTree.Freshness"
    ],
    [
      struct: "MingaEditor.State.FileTree",
      owners: ["MingaEditor.State.FileTree"],
      paths: [[:file_tree]],
      boundary: "MingaEditor.State.FileTree transition API",
      workflow: "MingaEditor.FileTree.Freshness or a focused file-tree workflow"
    ],
    [
      struct: "MingaEditor.State.RenderCorrelation",
      owners: ["MingaEditor.State.RenderCorrelation"],
      paths: [[:render_correlation]],
      boundary: "MingaEditor.State.RenderCorrelation transition API",
      workflow: "MingaEditor.RenderPipeline or MingaEditor.Handlers.RenderHandler"
    ],
    [
      struct: "MingaEditor.State.Frontend",
      owners: ["MingaEditor.State.Frontend"],
      paths: [[:frontend]],
      boundary:
        "MingaEditor.State.Frontend transition API for frontend capability, viewport, and input correlation",
      workflow: "the focused frontend connection or render workflow"
    ],
    [
      struct: "MingaEditor.State.Render",
      owners: ["MingaEditor.State.Render"],
      paths: [[:render]],
      boundary:
        "MingaEditor.State.Render transition API for renderer connection, layout observations, and message storage",
      workflow: "MingaEditor.RenderPipeline or a focused render workflow"
    ],
    [
      struct: "MingaEditor.State.Parser",
      owners: ["MingaEditor.State.Parser"],
      paths: [[:parser]],
      boundary:
        "MingaEditor.State.Parser transition API for parser availability and derived highlight caches",
      workflow: "the focused parser or highlighting workflow"
    ],
    [
      struct: "MingaEditor.State.AgentConnection",
      owners: ["MingaEditor.State.AgentConnection"],
      paths: [[:agent_connection]],
      boundary:
        "MingaEditor.State.AgentConnection transition API for agent transport and session connection state",
      workflow: "the focused agent connection workflow"
    ],
    [
      struct: "MingaEditor.State.Interaction",
      owners: ["MingaEditor.State.Interaction"],
      paths: [[:interaction]],
      boundary:
        "MingaEditor.State.Interaction transition API for input model, focus routing, and keystroke history",
      workflow: "the focused input workflow"
    ],
    [
      struct: "MingaEditor.State.ExtensionSurfaces",
      owners: ["MingaEditor.State.ExtensionSurfaces"],
      paths: [[:extension_surfaces]],
      boundary:
        "MingaEditor.State.ExtensionSurfaces transition API for per-editor extension registry identities",
      workflow: "the focused extension lifecycle workflow"
    ],
    [
      struct: "MingaEditor.State.BufferLifecycle",
      owners: ["MingaEditor.State.BufferLifecycle"],
      paths: [[:buffer_lifecycle]],
      boundary:
        "MingaEditor.State.BufferLifecycle transition API for buffer registration and retirement metadata",
      workflow: "the focused buffer lifecycle workflow"
    ],
    [
      struct: "MingaEditor.State.Git",
      owners: ["MingaEditor.State.Git"],
      paths: [[:git]],
      boundary: "MingaEditor.State.Git transition API for Git status and diff presentation state",
      workflow: "the focused Git workflow"
    ],
    [
      struct: "MingaEditor.State.Session",
      owners: ["MingaEditor.State.Session"],
      paths: [[:session]],
      boundary:
        "MingaEditor.State.Session transition API for session persistence configuration and timer intent",
      workflow: "MingaEditor.Handlers.SessionHandler or MingaEditor.Startup"
    ],
    [
      struct: "MingaEditor.State.Feedback",
      owners: ["MingaEditor.State.Feedback"],
      paths: [[:feedback]],
      boundary:
        "MingaEditor.State.Feedback transition API for operation progress and user-facing feedback values",
      workflow: "the focused operation feedback workflow"
    ],
    [
      struct: "MingaEditor.State.LSP",
      owners: ["MingaEditor.State.LSP"],
      paths: [[:lsp]],
      boundary:
        "MingaEditor.State.LSP transition API for server status, responses, requests, and timer intent",
      workflow: "MingaEditor.LSPActions or the focused LSP event workflow"
    ],
    [
      struct: "MingaEditor.State.Remote",
      owners: ["MingaEditor.State.Remote"],
      paths: [[:remote]],
      boundary: "MingaEditor.State.Remote transition API for remote session and file state",
      workflow: "the focused remote session workflow"
    ],
    [
      struct: "MingaEditor.State.Appearance",
      owners: ["MingaEditor.State.Appearance"],
      paths: [[:appearance]],
      boundary:
        "MingaEditor.State.Appearance transition API for theme and display preference state",
      workflow: "the focused appearance workflow"
    ],
    [
      struct: "MingaEditor.State",
      owners: ["MingaEditor.State"],
      paths: [],
      boundary: "MingaEditor.State root transition API for a documented root-wide invariant",
      workflow: "the focused Editor workflow that owns the external action"
    ],
    [
      struct: "MingaEditor.State.Mouse",
      owners: ["MingaEditor.State.Mouse"],
      paths: [[:workspace, :mouse]],
      boundary:
        "MingaEditor.State.Mouse transition API for drag, click, and hover presentation values",
      workflow: "MingaEditor.Mouse"
    ],
    [
      struct: "MingaEditor.Session.State",
      owners: ["MingaEditor.Session.State"],
      paths: [[:workspace]],
      boundary: "MingaEditor.Session.State aggregate transition API",
      workflow:
        "a focused Editor workflow or MingaEditor.State for a documented root-wide invariant"
    ],
    [
      struct: "MingaEditor.Session.HoverObservation",
      owners: ["MingaEditor.Session.HoverObservation"],
      paths: [[:workspace, :hover_observation]],
      boundary: "MingaEditor.Session.HoverObservation transition API",
      workflow: "a focused Editor hover workflow"
    ],
    [
      struct: "MingaEditor.Shell.Runtime",
      owners: ["MingaEditor.Shell.Runtime"],
      paths: [[:shell_runtime]],
      boundary: "MingaEditor.Shell.Runtime transition API",
      workflow: "MingaEditor.Shell.Workflow"
    ],
    [
      struct: "MingaEditor.Shell.StateStash",
      owners: ["MingaEditor.Shell.StateStash"],
      paths: [],
      boundary: "MingaEditor.Shell.StateStash transition API",
      workflow: "MingaEditor.Shell.Workflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.State",
      owners: ["MingaEditor.Shell.Traditional.State"],
      paths: [[:shell_state]],
      boundary: "MingaEditor.Shell.Traditional.State aggregate transition API",
      workflow: "a focused MingaEditor.Shell.Traditional workflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.Flashes",
      owners: ["MingaEditor.Shell.Traditional.Flashes"],
      paths: [[:flashes]],
      boundary: "MingaEditor.Shell.Traditional.Flashes transition API",
      workflow: "MingaEditor.Shell.Traditional.FlashesWorkflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.NavFlash",
      owners: ["MingaEditor.Shell.Traditional.NavFlash"],
      paths: [[:flashes, :nav]],
      boundary: "MingaEditor.Shell.Traditional.NavFlash transition API",
      workflow: "MingaEditor.Shell.Traditional.FlashesWorkflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.YankFlash",
      owners: ["MingaEditor.Shell.Traditional.YankFlash"],
      paths: [[:flashes, :yank]],
      boundary: "MingaEditor.Shell.Traditional.YankFlash transition API",
      workflow: "MingaEditor.Shell.Traditional.FlashesWorkflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.Notice",
      owners: ["MingaEditor.Shell.Traditional.Notice"],
      paths: [[:notice]],
      boundary: "MingaEditor.Shell.Traditional.Notice transition API",
      workflow: "MingaEditor.Shell.Traditional.NoticeWorkflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.GitToast",
      owners: ["MingaEditor.Shell.Traditional.GitToast"],
      paths: [[:git_toast]],
      boundary: "MingaEditor.Shell.Traditional.GitToast transition API",
      workflow: "MingaEditor.Shell.Traditional.GitToastWorkflow"
    ],
    [
      struct: "MingaEditor.State.WhichKey",
      owners: ["MingaEditor.State.WhichKey"],
      paths: [[:whichkey]],
      boundary: "MingaEditor.State.WhichKey transition API",
      workflow: "MingaEditor.Shell.Traditional.WhichKeyWorkflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.Sidebars",
      owners: ["MingaEditor.Shell.Traditional.Sidebars"],
      paths: [[:sidebars]],
      boundary: "MingaEditor.Shell.Traditional.Sidebars transition API",
      workflow: "MingaEditor.Shell.Traditional.SidebarWorkflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.Observatory",
      owners: ["MingaEditor.Shell.Traditional.Observatory"],
      paths: [[:sidebars, :observatory]],
      boundary: "MingaEditor.Shell.Traditional.Observatory transition API",
      workflow: "MingaEditor.Shell.Traditional.SidebarWorkflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.AgentSurfaces",
      owners: ["MingaEditor.Shell.Traditional.AgentSurfaces"],
      paths: [[:agent_surfaces]],
      boundary: "MingaEditor.Shell.Traditional.AgentSurfaces transition API",
      workflow: "a focused Traditional agent workflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.ToolPrompts",
      owners: ["MingaEditor.Shell.Traditional.ToolPrompts"],
      paths: [[:tool_prompts]],
      boundary: "MingaEditor.Shell.Traditional.ToolPrompts transition API",
      workflow: "MingaEditor.Shell.Traditional.ToolPromptWorkflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.InputState",
      owners: ["MingaEditor.Shell.Traditional.InputState"],
      paths: [[:input]],
      boundary: "MingaEditor.Shell.Traditional.InputState transition API",
      workflow: "a focused Traditional input workflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.SpaceLeader",
      owners: ["MingaEditor.Shell.Traditional.SpaceLeader"],
      paths: [[:input, :space_leader]],
      boundary: "MingaEditor.Shell.Traditional.SpaceLeader transition API",
      workflow: "a focused Traditional input workflow"
    ],
    [
      struct: "MingaEditor.Shell.Traditional.ClickRegions",
      owners: ["MingaEditor.Shell.Traditional.ClickRegions"],
      paths: [[:input, :click_regions]],
      boundary: "MingaEditor.Shell.Traditional.ClickRegions transition API",
      workflow: "the Traditional render/input workflow"
    ],
    [
      struct: "MingaEditor.Agent.UIState",
      owners: ["MingaEditor.Agent.UIState", "MingaEditor.Agent.UIState.Presentation"],
      paths: [[:agent_ui]],
      boundary:
        "MingaEditor.Agent.UIState or MingaEditor.Agent.UIState.Presentation transition API",
      workflow: "a focused Editor agent workflow"
    ],
    [
      struct: "MingaEditor.State.TabBar",
      owners: ["MingaEditor.State.TabBar"],
      paths: [[:tab_bar]],
      boundary: "MingaEditor.State.TabBar tab and workspace transition API",
      workflow: "a focused tab or workspace workflow"
    ],
    [
      struct: "MingaEditor.State.Tab",
      owners: ["MingaEditor.State.Tab"],
      paths: [],
      boundary: "MingaEditor.State.Tab transition API",
      workflow: "a focused tab workflow"
    ],
    [
      struct: "MingaEditor.State.Tab.Context",
      owners: ["MingaEditor.State.Tab.Context"],
      paths: [],
      boundary: "MingaEditor.State.Tab.Context snapshot transition API",
      workflow: "a focused tab workflow"
    ],
    [
      struct: "MingaEditor.State.Workspace",
      owners: ["MingaEditor.State.Workspace"],
      paths: [],
      pure: false,
      boundary: "MingaEditor.State.Workspace transition API",
      workflow: "a focused workspace workflow"
    ],
    [
      struct: "MingaEditor.BottomPanel",
      owners: ["MingaEditor.BottomPanel"],
      paths: [[:bottom_panel]],
      boundary: "MingaEditor.BottomPanel transition API",
      workflow: "a focused Traditional panel workflow"
    ],
    [
      struct: "MingaEditor.State.ModalOverlay",
      owners: ["MingaEditor.State.ModalOverlay"],
      paths: [[:modal]],
      generic_api: false,
      boundary: "MingaEditor.State.ModalOverlay transition API",
      workflow: "MingaEditor.Shell.Traditional.ModalWorkflow"
    ],
    [
      struct: "MingaEditor.State.ModalOverlay.Picker",
      owners: ["MingaEditor.State.ModalOverlay.Picker"],
      paths: [],
      pure: false,
      boundary: "MingaEditor.State.ModalOverlay.Picker transition API",
      workflow: "MingaEditor.Shell.Traditional.ModalWorkflow"
    ],
    [
      struct: "MingaEditor.State.ModalOverlay.Prompt",
      owners: ["MingaEditor.State.ModalOverlay.Prompt"],
      paths: [],
      pure: false,
      boundary: "MingaEditor.State.ModalOverlay.Prompt transition API",
      workflow: "MingaEditor.Shell.Traditional.ModalWorkflow"
    ],
    [
      struct: "MingaEditor.State.ModalOverlay.Completion",
      owners: ["MingaEditor.State.ModalOverlay.Completion"],
      paths: [],
      pure: false,
      boundary: "MingaEditor.State.ModalOverlay.Completion transition API",
      workflow: "MingaEditor.Shell.Traditional.ModalWorkflow"
    ],
    [
      struct: "MingaEditor.State.ModalOverlay.CommandCompletion",
      owners: ["MingaEditor.State.ModalOverlay.CommandCompletion"],
      paths: [],
      pure: false,
      boundary: "MingaEditor.State.ModalOverlay.CommandCompletion transition API",
      workflow: "MingaEditor.Shell.Traditional.ModalWorkflow"
    ],
    [
      struct: "MingaEditor.State.ModalOverlay.Conflict",
      owners: ["MingaEditor.State.ModalOverlay.Conflict"],
      paths: [],
      pure: false,
      boundary: "MingaEditor.State.ModalOverlay.Conflict transition API",
      workflow: "MingaEditor.Shell.Traditional.ModalWorkflow"
    ]
  ]

  @process_modules ~w(Process GenServer Task Agent Registry DynamicSupervisor Supervisor)
  @boundary_prefixes [
    "File",
    "System",
    ":timer",
    ":file",
    ":gen_server",
    "Minga.Log",
    "Minga.Events",
    "Minga.Buffer",
    "Minga.Session",
    "Minga.LSP",
    "Minga.Git",
    "Minga.Keymap",
    "Minga.Config.Options",
    "MingaAgent",
    "MingaEditor.Extension.Sidebar",
    "MingaEditor.Agent.SemanticUI.Registry",
    "MingaEditor.Renderer",
    "MingaEditor.RenderPipeline",
    "MingaEditor.Session",
    "MingaEditor.Frontend",
    "MingaEditor.EffectScheduler"
  ]
  @boundary_segments ~w(Workflow Workflows Registry Replay Renderer Rendering Persistence Storage Service Services)
  @value_modules [
    "MingaEditor.Renderer.ReceiptProjection",
    "MingaEditor.Renderer.RenderReceipt",
    "Minga.Keymap.Scope",
    "MingaAgent.Branch",
    "MingaAgent.Changeset.BudgetExhaustedEvent",
    "MingaAgent.Changeset.MergedEvent",
    "MingaAgent.CostCalculator",
    "MingaAgent.EditBoundary",
    "MingaAgent.Event",
    "MingaAgent.EventLog.EventRecord",
    "MingaAgent.EventLog.Taxonomy",
    "MingaAgent.Hooks.Hook",
    "MingaAgent.Hooks.NotificationPayload",
    "MingaAgent.Hooks.PostToolUsePayload",
    "MingaAgent.Hooks.PreCompactPayload",
    "MingaAgent.Hooks.PreToolUsePayload",
    "MingaAgent.Hooks.Result",
    "MingaAgent.Hooks.SessionEndPayload",
    "MingaAgent.Hooks.SessionStartPayload",
    "MingaAgent.Hooks.StopPayload",
    "MingaAgent.Hooks.UserPromptSubmitPayload",
    "MingaAgent.Instruction",
    "MingaAgent.InternalState",
    "MingaAgent.MCP.ServerConfig",
    "MingaAgent.MCP.Tool",
    "MingaAgent.MCP.Transport",
    "MingaAgent.Message",
    "MingaAgent.ModelLimits",
    "MingaAgent.OAuth.PendingFlow.Entry",
    "MingaAgent.Provider",
    "MingaAgent.Provider.Spec",
    "MingaAgent.Redaction",
    "MingaAgent.RuntimeState",
    "MingaAgent.Subagent.Handle",
    "MingaAgent.TodoItem",
    "MingaAgent.TokenEstimator",
    "MingaAgent.Tool.Spec",
    "MingaAgent.ToolApproval.Preview",
    "MingaAgent.ToolCall",
    "MingaAgent.TurnUsage"
  ]

  @doc "Returns the protected Editor value ledger."
  @spec ownerships() :: [ownership()]
  def ownerships, do: @ownerships

  @doc "Returns the default pure-owner selector."
  @spec pure_modules() :: :owners
  def pure_modules, do: :owners

  @doc "Returns the exception policy. EX9012 intentionally accepts no exceptions."
  @spec allowlist() :: []
  def allowlist, do: []

  @doc "Returns exact process and registry module boundaries."
  @spec process_modules() :: [String.t()]
  def process_modules, do: @process_modules

  @doc "Returns module prefixes that always cross a pure-owner boundary."
  @spec boundary_prefixes() :: [String.t()]
  def boundary_prefixes, do: @boundary_prefixes

  @doc "Returns module-name segments that identify workflow or service boundaries."
  @spec boundary_segments() :: [String.t()]
  def boundary_segments, do: @boundary_segments

  @doc "Returns pure value modules that may be called by other value owners."
  @spec value_modules() :: [String.t()]
  def value_modules, do: @value_modules
end
