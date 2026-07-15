defmodule Minga.Services.Supervisor do
  @moduledoc """
  Supervises application services: git tracking, extensions, LSP, diagnostics, and more.

  Uses `rest_for_one` at this level to preserve two dependency chains:

  1. Extension.Registry → Extension.Supervisor → Config.Loader
     (Loader evaluates user config that registers and starts extensions)
  2. LSP.Supervisor → LSP.SyncServer
     (SyncServer calls into LSP.Supervisor to ensure clients)

  Independent services (Git.Tracker, Diagnostics, Command.Registry, etc.)
  are grouped under a nested `one_for_one` supervisor so that a single
  service crash restarts only that service without cascading into its
  siblings or the dependency chains below.

  ## Children

      Services.Supervisor (rest_for_one)
      ├── Services.Independent (one_for_one)
      │   ├── Minga.Git.Tracker              Subscribes to buffer events, ETS registry
      │   ├── Minga.CommandOutput.Registry    Registry(:unique)
      │   ├── Minga.Eval.TaskSupervisor      Task.Supervisor for eval/async work
      │   ├── Minga.Command.Registry         Named command lookup
      │   └── Minga.Diagnostics              ETS-backed diagnostics store
      ├── Minga.Extension.Registry           Extension metadata (Agent)
      ├── MingaEditor.Extension.Sidebar      Source-owned editor sidebar registry
      ├── Minga.Extension.ArtifactGenerationState Persistent VM-generation provenance owner
      ├── Minga.Extension.ArtifactAdmission  VM-generation module admission serializer
      ├── Minga.Extension.CodeLease          Process-owned leases for extension callback modules
      ├── MingaAgent.ProviderRegistry        Source-owned provider declarations
      ├── MingaAgent.ProviderPacks.Native    Bundled native provider declaration
      ├── MingaAgent.Hooks.Registry          Source-owned agent hook declarations
      ├── MingaAgent.MCP.ServerRegistry      Source-owned MCP server declarations
      ├── MingaAgent.Skills.Registry         Source-owned extension skill paths
      ├── MingaEditor.Agent.SlashCommand.Registry Source-owned agent slash commands
      ├── MingaEditor.Agent.SemanticUI.Registry Source-owned semantic agent UI contributions
      ├── Minga.Extension.Supervisor         DynamicSupervisor for extension processes
      ├── Minga.Config.Loader                Evaluates user config on init
      ├── Minga.Config.Writer                Debounced GUI settings overlay writer
      ├── Minga.LSP.Supervisor               DynamicSupervisor for LSP clients
      ├── Minga.LSP.SyncServer               Subscribes to buffer events, manages LSP sync
      ├── Minga.Project                      Project root detection, file cache
      └── MingaAgent.SessionManager          Session ID → PID registry, lifecycle events
      └── MingaAgent.ReactiveDiagnostics     Opt-in saved-file LSP error suggestions

  MingaAgent.Supervisor was promoted to a top-level peer of Minga.Supervisor
  (between Services and Runtime) to support headless operation.

  Project is placed after LSP.SyncServer to match the dependency direction:
  SyncServer uses RootDetector which may consult Project. A Project crash
  cascades only to SessionManager. Provider and agent contribution registries start before extension supervision and config loading so extension contributions can register during boot and cleanup callbacks exist before extension reloads. The bundled native provider pack starts immediately after the provider registry so the default provider is contributed through the same source-owned path as future provider packs.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(_opts) do
    Minga.Telemetry.StartupTimer.mark(:services_init)

    alias Minga.Telemetry.StartupTimer

    children = [
      StartupTimer.timed_child_spec(:svc_independent, Minga.Services.Independent),
      StartupTimer.timed_child_spec(:svc_ext_registry, Minga.Extension.Registry),
      StartupTimer.timed_child_spec(:svc_sidebar, MingaEditor.Extension.Sidebar),
      StartupTimer.timed_child_spec(
        :svc_artifact_generation_state,
        Minga.Extension.ArtifactGenerationState
      ),
      StartupTimer.timed_child_spec(
        :svc_artifact_admission,
        Minga.Extension.ArtifactAdmission
      ),
      StartupTimer.timed_child_spec(:svc_code_lease, Minga.Extension.CodeLease),
      StartupTimer.timed_child_spec(:svc_provider_registry, MingaAgent.ProviderRegistry),
      StartupTimer.timed_child_spec(:svc_provider_packs, MingaAgent.ProviderPacks.Native),
      StartupTimer.timed_child_spec(:svc_hooks_registry, MingaAgent.Hooks.Registry),
      StartupTimer.timed_child_spec(:svc_mcp_registry, MingaAgent.MCP.ServerRegistry),
      StartupTimer.timed_child_spec(:svc_skills_registry, MingaAgent.Skills.Registry),
      StartupTimer.timed_child_spec(
        :svc_slash_cmd_registry,
        MingaEditor.Agent.SlashCommand.Registry
      ),
      StartupTimer.timed_child_spec(
        :svc_semantic_ui_registry,
        MingaEditor.Agent.SemanticUI.Registry
      ),
      StartupTimer.timed_child_spec(:svc_ext_supervisor, Minga.Extension.Supervisor),
      StartupTimer.timed_child_spec(:svc_config_loader, Minga.Config.Loader),
      StartupTimer.timed_child_spec(:svc_config_writer, Minga.Config.Writer),
      StartupTimer.timed_child_spec(:svc_lsp_supervisor, Minga.LSP.Supervisor),
      StartupTimer.timed_child_spec(:svc_lsp_sync, Minga.LSP.SyncServer),
      StartupTimer.timed_child_spec(:svc_project, Minga.Project),
      StartupTimer.timed_child_spec(:svc_session_manager, MingaAgent.SessionManager),
      StartupTimer.timed_child_spec(:svc_reactive_diag, MingaAgent.ReactiveDiagnostics)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
