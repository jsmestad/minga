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
      │   ├── Minga.Editing.Fold.Registry            Fold state
      │   └── Minga.Diagnostics              ETS-backed diagnostics store
      ├── Minga.Extension.Registry           Extension metadata (Agent)
      ├── Minga.Extension.Supervisor         DynamicSupervisor for extension processes
      ├── Minga.Config.Loader                Evaluates user config on init
      ├── Minga.LSP.Supervisor               DynamicSupervisor for LSP clients
      ├── Minga.LSP.SyncServer               Subscribes to buffer events, manages LSP sync
      ├── Minga.Project                      Project root detection, file cache
      └── MingaAgent.SessionManager          Session ID → PID registry, lifecycle events

  MingaAgent.Supervisor was promoted to a top-level peer of Minga.Supervisor
  (between Services and Runtime) to support headless operation.

  Project is placed after LSP.SyncServer to match the dependency direction:
  SyncServer uses RootDetector which may consult Project. A Project crash
  cascades only to SessionManager.
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
    children = [
      # Independent services under one_for_one: a single service crash
      # restarts only that service, not its siblings or the chains below.
      Minga.Services.Independent,

      # Extension chain: Registry → Supervisor → Loader
      Minga.Extension.Registry,
      Minga.Extension.Supervisor,
      Minga.Config.Loader,

      # LSP chain: Supervisor → SyncServer
      Minga.LSP.Supervisor,
      Minga.LSP.SyncServer,

      # Project and session manager (end of chain, minimal cascade)
      Minga.Project,
      MingaAgent.SessionManager
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
