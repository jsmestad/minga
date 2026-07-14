defmodule MingaEditor.Supervisor do
  @moduledoc """
  Supervises the editor runtime: parser, renderer server, and Editor generation.

  Uses `rest_for_one` to enforce the dependency chain:

      MingaEditor.Supervisor (rest_for_one)
      ├── Minga.Parser.Manager            Tree-sitter parser Port
      ├── MingaEditor.Frontend.Manager    Zig/Metal frontend Port
      ├── MingaEditor.Renderer.Server     Async render pipeline
      ├── MingaEditor.GenerationSupervisor (one_for_all)
      │   ├── MingaEditor.EffectTaskSupervisor
      │   ├── MingaEditor.EffectScheduler
      │   └── MingaEditor                 Editor orchestration GenServer
      └── MingaEditor.NativeIPC.Supervisor bundled macOS control socket (GUI only)

  If Parser.Manager crashes, everything below restarts. If Frontend.Manager
  crashes, Renderer.Server and the Editor generation restart. If
  Renderer.Server crashes, the generation restarts because the Editor holds a
  resolved renderer pid. An Editor crash tears down its scheduler and every old
  effect worker before replacement authority starts.

  This supervisor is conditionally started: it only appears in the
  supervision tree when the editor UI is active (not in test mode or
  headless operation).
  """

  use Supervisor

  @typedoc "Options for starting the editor supervisor."
  @type start_opt ::
          {:name, GenServer.name()} | {:backend, MingaEditor.Frontend.Manager.backend()}

  @spec start_link([start_opt()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    Minga.Telemetry.StartupTimer.mark(:editor_supervisor_init)
    backend = Keyword.get(opts, :backend, :tui)

    alias MingaEditor.Frontend.Resolve
    renderer_path = Resolve.renderer_path(backend)
    tty_path = Resolve.tty_path()

    children =
      [
        Minga.Parser.Manager,
        {MingaEditor.Frontend.Manager,
         [backend: backend, renderer_path: renderer_path, tty_path: tty_path]}
      ]
      |> Enum.concat(renderer_children())
      |> Enum.concat(generation_children(backend))
      |> Enum.concat(native_ipc_children(backend))

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @spec renderer_children() :: [module()]
  defp renderer_children, do: [MingaEditor.Renderer.Server]

  @spec generation_children(MingaEditor.Frontend.Manager.backend()) :: [{module(), keyword()}]
  defp generation_children(backend) do
    [
      {MingaEditor.GenerationSupervisor,
       [
         editor:
           {MingaEditor,
            [
              backend: backend,
              swap_dir: Minga.Session.swap_dir(),
              session_dir: Path.dirname(Minga.Session.session_file())
            ]}
       ]}
    ]
  end

  @spec native_ipc_children(MingaEditor.Frontend.Manager.backend()) :: [module()]
  defp native_ipc_children(:gui) do
    if System.get_env("MINGA_PORT_MODE") == "connected" and :os.type() == {:unix, :darwin} do
      [MingaEditor.NativeIPC.Supervisor]
    else
      []
    end
  end

  defp native_ipc_children(_backend), do: []
end
