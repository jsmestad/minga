defmodule MingaEditor.Supervisor do
  @moduledoc """
  Supervises the editor runtime: parser, renderer server, and Editor GenServer.

  Uses `rest_for_one` to enforce the dependency chain:

      MingaEditor.Supervisor (rest_for_one)
      ├── Minga.Parser.Manager            Tree-sitter parser Port
      ├── MingaEditor.Extension.Sidebar   Source-owned sidebar registry
      ├── MingaEditor.Frontend.Manager    Zig/Metal frontend Port
      ├── MingaEditor.Renderer.Server     Async render pipeline
      └── MingaEditor                     Editor orchestration GenServer

  If Parser.Manager crashes, everything below restarts. If Frontend.Manager
  crashes, Renderer.Server and Editor restart. If Renderer.Server crashes,
  Editor restarts (it holds a resolved pid that would be stale). An Editor
  crash restarts only the Editor.

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
    backend = Keyword.get(opts, :backend, :tui)

    children =
      [
        Minga.Parser.Manager,
        MingaEditor.Extension.Sidebar,
        {MingaEditor.Frontend.Manager, [backend: backend]}
      ] ++
        renderer_children() ++
        [
          {MingaEditor,
           [
             backend: backend,
             swap_dir: Minga.Session.swap_dir(),
             session_dir: Path.dirname(Minga.Session.session_file())
           ]}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @spec renderer_children() :: [module()]
  defp renderer_children, do: [MingaEditor.Renderer.Server]
end
