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
      ├── MingaAgent.ModelCatalog        Shares the one model catalog load
      ├── Minga.Command.Registry         Named command lookup
      ├── MingaAgent.StatusCommand       Cached agent status command output
      ├── Minga.Diagnostics              ETS-backed diagnostics store
      ├── Minga.Search.IndexOwner        Source-owned current GUI search indexes
      ├── Minga.Session.EventRecorder            Persistent editor event log (SQLite via exqlite)
      ├── MingaAgent.EventLog                    Persistent agent session event log
      ├── MingaAgent.StagedDraftKeeper.Scope     :pg scope of live staged views
      ├── MingaAgent.StagedDraftKeeper           Durable staged agent edits (survive restarts)
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
    alias Minga.Telemetry.StartupTimer

    children = [
      StartupTimer.timed_child_spec(
        :ind_git_repo_reg,
        {Registry, keys: :unique, name: Minga.Git.Repo.Registry}
      ),
      StartupTimer.timed_child_spec(
        :ind_git_repo_sup,
        {DynamicSupervisor, name: Minga.Git.Repo.Supervisor, strategy: :one_for_one}
      ),
      StartupTimer.timed_child_spec(:ind_git_tracker, Minga.Git.Tracker),
      StartupTimer.timed_child_spec(
        :ind_cmd_out_reg,
        {Registry, keys: :unique, name: Minga.CommandOutput.Registry}
      ),
      StartupTimer.timed_child_spec(
        :ind_eval_sup,
        {Task.Supervisor, name: Minga.Eval.TaskSupervisor}
      ),
      StartupTimer.timed_child_spec(:ind_model_catalog, MingaAgent.ModelCatalog),
      StartupTimer.timed_child_spec(:ind_cmd_registry, Minga.Command.Registry),
      StartupTimer.timed_child_spec(:ind_status_cmd, MingaAgent.StatusCommand),
      StartupTimer.timed_child_spec(:ind_conn_mgr, Minga.Distribution.ConnectionManager),
      StartupTimer.timed_child_spec(:ind_diagnostics, Minga.Diagnostics),
      StartupTimer.timed_child_spec(:ind_search_index, Minga.Search.IndexOwner),
      StartupTimer.timed_child_spec(:ind_event_recorder, Minga.Session.EventRecorder),
      StartupTimer.timed_child_spec(:ind_agent_event_log, MingaAgent.EventLog),
      # Live changesets announce their staged views in this :pg scope; it
      # outlives a keeper crash so the restarted keeper can adopt them, and
      # monitors (never links) its members.
      StartupTimer.timed_child_spec(:ind_staged_drafts_scope, %{
        id: MingaAgent.StagedDraftKeeper.Scope,
        start: {:pg, :start_link, [MingaAgent.StagedDraftKeeper.Scope]}
      }),
      StartupTimer.timed_child_spec(:ind_staged_drafts, MingaAgent.StagedDraftKeeper),
      StartupTimer.timed_child_spec(:ind_oauth_flow, MingaAgent.OAuth.PendingFlow),
      StartupTimer.timed_child_spec(:ind_tool_manager, Minga.Tool.Manager)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
