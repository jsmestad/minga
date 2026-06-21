defmodule MingaEditor.Collab.SessionSupervisor do
  @moduledoc """
  Supervises one collab session's editor triad.

      SessionSupervisor (rest_for_one)
      ├── MingaEditor.Frontend.Manager    frontend Port (named per session)
      ├── MingaEditor.Renderer.Server     async render pipeline (named per session)
      └── MingaEditor                     editor orchestration (named per session)

  Each child is registered under a `{session_id, role}` via-tuple in
  `MingaEditor.Collab.Registry` (the default session also keeps its historical
  bare module names). The renderer is wired to its session's editor name and the
  editor is wired to its session's frontend name, so the triad resolves to
  itself rather than to a global singleton.

  `Minga.Parser.Manager` and the buffer registry/supervisor are intentionally
  *not* started here: they are node-shared so sessions opening the same path
  resolve to one shared `Minga.Buffer.Process`.

  `rest_for_one` keeps the dependency chain: a Frontend crash restarts the
  Renderer and Editor; a Renderer crash restarts only the Editor; an Editor
  crash restarts only itself.
  """

  use Supervisor

  alias MingaEditor.Collab.Names

  @typedoc "Options for starting a session triad."
  @type start_opt ::
          {:session_id, Names.session_id()}
          | {:backend, MingaEditor.Frontend.Manager.backend()}
          | {:swap_dir, String.t()}
          | {:session_dir, String.t()}

  @doc """
  Starts a session triad supervisor.

  Requires `:session_id`. The supervisor itself is registered under the session's
  `:supervisor` via-tuple so the dynamic supervisor and teardown can find it.
  """
  @spec start_link([start_opt()]) :: Supervisor.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Supervisor.start_link(__MODULE__, opts, name: supervisor_name(session_id))
  end

  @doc "The via-name a session triad supervisor registers under."
  @spec supervisor_name(Names.session_id()) ::
          {:via, Registry, {module(), {Names.session_id(), :supervisor}}} | module()
  def supervisor_name(session_id) do
    if Names.default_session?(session_id) do
      __MODULE__
    else
      {:via, Registry, {Names.registry(), {session_id, :supervisor}}}
    end
  end

  @impl true
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    backend = Keyword.get(opts, :backend, :tui)
    swap_dir = Keyword.get(opts, :swap_dir, Minga.Session.swap_dir())
    session_dir = Keyword.get(opts, :session_dir, Path.dirname(Minga.Session.session_file()))

    renderer_name = Names.name(session_id, :renderer)
    editor_name = Names.name(session_id, :editor)

    children =
      frontend_children(session_id, backend) ++
        renderer_children(renderer_name, editor_name, backend) ++
        [
          Supervisor.child_spec(
            {MingaEditor,
             [
               name: editor_name,
               session_id: session_id,
               port_manager: port_manager(session_id, backend),
               backend: backend,
               swap_dir: swap_dir,
               session_dir: session_dir
             ]},
            id: :editor
          )
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Headless renders in-process with no Port, so it needs neither a
  # Frontend.Manager nor a Renderer.Server. tui/gui get the full triad.
  @spec frontend_children(Names.session_id(), atom()) :: [Supervisor.child_spec()]
  defp frontend_children(_session_id, :headless), do: []

  defp frontend_children(session_id, backend) do
    [
      Supervisor.child_spec(
        {MingaEditor.Frontend.Manager,
         [name: Names.name(session_id, :frontend), backend: backend]},
        id: :frontend
      )
    ]
  end

  @spec renderer_children(GenServer.name(), GenServer.name(), atom()) :: [Supervisor.child_spec()]
  defp renderer_children(_renderer_name, _editor_name, :headless), do: []

  defp renderer_children(renderer_name, editor_name, _backend) do
    [
      Supervisor.child_spec(
        {MingaEditor.Renderer.Server, [name: renderer_name, editor_pid: editor_name]},
        id: :renderer
      )
    ]
  end

  @spec port_manager(Names.session_id(), atom()) :: GenServer.name() | nil
  defp port_manager(_session_id, :headless), do: nil
  defp port_manager(session_id, _backend), do: Names.name(session_id, :frontend)
end
