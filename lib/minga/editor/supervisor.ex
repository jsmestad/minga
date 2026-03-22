defmodule Minga.Editor.Supervisor do
  @moduledoc """
  Supervises the editor runtime: tree-sitter parser, renderer, and Editor GenServer.

  Uses `rest_for_one` to enforce the dependency chain:

      Editor.Supervisor (rest_for_one)
      ├── Minga.Parser.Manager     Tree-sitter parser Port
      ├── Minga.Port.Manager       Zig renderer Port
      └── Minga.Editor             Editor orchestration GenServer

  If Parser.Manager crashes, Port.Manager and Editor restart (Editor has
  stale highlight state). If Port.Manager crashes, Editor restarts (Editor
  can't render without the Port). An Editor crash restarts only the Editor.

  This supervisor is conditionally started: it only appears in the
  supervision tree when the editor UI is active (not in test mode or
  headless operation).
  """

  use Supervisor

  @typedoc "Options for starting the editor supervisor."
  @type start_opt :: {:name, GenServer.name()} | {:backend, Minga.Port.Manager.backend()}

  @spec start_link([start_opt()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    backend = Keyword.get(opts, :backend, :tui)

    children = [
      Minga.Parser.Manager,
      {Minga.Port.Manager, [backend: backend]},
      {Minga.Editor,
       [
         swap_dir: Minga.Swap.swap_dir(),
         session_dir: Path.dirname(Minga.Session.session_file())
       ]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
