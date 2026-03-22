defmodule Minga.Services.Independent do
  @moduledoc """
  Supervises independent services that have no ordering dependencies.

  Uses `one_for_one` so that a single service crash (e.g., Git.Tracker,
  Diagnostics) restarts only that service without cascading into siblings
  or the dependency chains in `Services.Supervisor`.

  ## Children

      Services.Independent (one_for_one)
      ├── Minga.Git.Repo.Registry        Registry(:unique) for per-repo GenServers
      ├── Minga.Git.Repo.Supervisor      DynamicSupervisor for Git.Repo processes
      ├── Minga.Git.Tracker              Subscribes to buffer events, ETS registry
      ├── Minga.CommandOutput.Registry    Registry(:unique)
      ├── Minga.Eval.TaskSupervisor      Task.Supervisor for eval/async work
      ├── Minga.Command.Registry         Named command lookup
      ├── Minga.Fold.Registry            Fold state
      ├── Minga.Diagnostics              ETS-backed diagnostics store
      ├── Minga.Tool.Recipe.Registry     Tool install recipe catalog
      └── Minga.Tool.Manager             Tool install/uninstall manager
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
      {Registry, keys: :unique, name: Minga.Git.Repo.Registry},
      {DynamicSupervisor, name: Minga.Git.Repo.Supervisor, strategy: :one_for_one},
      Minga.Git.Tracker,
      {Registry, keys: :unique, name: Minga.CommandOutput.Registry},
      {Task.Supervisor, name: Minga.Eval.TaskSupervisor},
      Minga.Command.Registry,
      Minga.Fold.Registry,
      Minga.Diagnostics,
      Minga.Tool.Recipe.Registry,
      Minga.Tool.Manager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
