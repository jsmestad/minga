defmodule MingaEditor.NativeIPC.Supervisor do
  @moduledoc """
  Owns the authenticated app-local Unix socket endpoint and its connections.

  This supervisor is started only for the bundled macOS GUI. A server restart
  also terminates every accepted connection so clients fail closed rather than
  attaching an in-flight request to a different core generation.
  """

  use Supervisor

  @typedoc "Supervisor option."
  @type start_opt ::
          {:name, Supervisor.supervisor() | nil}
          | {:server_name, GenServer.name() | nil}
          | {:task_supervisor_name, atom()}
          | MingaEditor.NativeIPC.Server.start_opt()

  @spec start_link([start_opt()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor_name, MingaEditor.NativeIPC.Tasks)
    server_name = Keyword.get(opts, :server_name, MingaEditor.NativeIPC.Server)

    children = [
      {Task.Supervisor, name: task_supervisor},
      {MingaEditor.NativeIPC.Server,
       opts
       |> Keyword.put(:name, server_name)
       |> Keyword.put(:task_supervisor, task_supervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
