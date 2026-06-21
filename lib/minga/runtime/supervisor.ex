defmodule Minga.Runtime.Supervisor do
  @moduledoc """
  Supervises the interactive editor runtime: watchdog, file watcher, and the editor core.

  Uses `one_for_one` so that each child restarts independently:

      Runtime.Supervisor (one_for_one)
      ├── Minga.Parser.Manager                  Tree-sitter parser Port (node-shared)
      ├── MingaEditor.Watchdog                   SIGUSR1 recovery (independent leaf)
      ├── Minga.FileWatcher                      FSEvents/inotify watcher (independent leaf)
      ├── MingaEditor.Collab.SessionManager      DynamicSupervisor for per-session triads
      └── MingaEditor.Collab.SessionSupervisor   default session: Frontend → Renderer → Editor

  A FileWatcher crash restarts only FileWatcher. A Watchdog crash restarts
  only Watchdog. Neither cascades into the session triads or each other. The
  tight Frontend → Renderer → Editor cascade is handled internally by each
  `MingaEditor.Collab.SessionSupervisor`'s own `rest_for_one` strategy.

  The parser is hoisted up to be node-shared so every collab session
  (the default one plus any attached clients) uses one tree-sitter Port.
  Additional client sessions are started under `SessionManager` on attach.

  This supervisor is conditionally started: it only appears in the tree
  when the editor UI is active (not in test mode or headless operation).
  """

  use Supervisor

  @typedoc "Options for starting the runtime supervisor."
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

    children = [
      # Parser is node-shared across all collab sessions. Started first so the
      # render path of every session triad has a parser to talk to. Hoisted out
      # of the per-session supervisor (#2424) so two sessions share one Port.
      Minga.Parser.Manager,
      # Watchdog starts early so it's ready to receive SIGUSR1 from the
      # moment the Editor boots. It's an independent leaf: its crash
      # restarts only itself under one_for_one.
      MingaEditor.Watchdog,
      # FileWatcher is a leaf: Editor receives messages from it but doesn't
      # depend on it structurally. A filesystem watcher flake restarts only
      # FileWatcher, not the renderer.
      Minga.FileWatcher,
      # DynamicSupervisor for additional client sessions started on attach.
      MingaEditor.Collab.SessionManager,
      # The default/singleton session triad. Groups the tightly-coupled render
      # path with rest_for_one: Frontend crash → Renderer + Editor restart,
      # Renderer crash → Editor restart. Registered under bare module names so
      # existing global lookups keep resolving.
      {MingaEditor.Collab.SessionSupervisor,
       [session_id: MingaEditor.Collab.Names.default_session_id(), backend: backend]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
