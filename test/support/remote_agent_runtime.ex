defmodule Minga.Test.RemoteAgentRuntime do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    db_dir =
      Keyword.get(opts, :db_dir, Path.join(System.tmp_dir!(), "minga-remote-agent-runtime"))

    File.mkdir_p!(db_dir)
    {:ok, options} = Minga.Config.Options.start_link([])
    {:ok, supervisor} = MingaAgent.Supervisor.start_link([])
    {:ok, manager} = MingaAgent.SessionManager.start_link([])
    {:ok, event_log} = MingaAgent.EventLog.start_link(db_dir: db_dir)
    {:ok, %{options: options, supervisor: supervisor, manager: manager, event_log: event_log}}
  end
end
