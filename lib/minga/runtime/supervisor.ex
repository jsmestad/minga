defmodule Minga.Runtime.Supervisor do
  @moduledoc """
  Supervises the interactive editor runtime: watchdog, file watcher, and the editor core.

  Uses `one_for_one` so that each child restarts independently:

      Runtime.Supervisor (one_for_one)
      ├── Minga.Editor.Watchdog      SIGUSR1 recovery (independent leaf)
      ├── Minga.FileWatcher          FSEvents/inotify watcher (independent leaf)
      └── Minga.Editor.Supervisor    Parser → Port → Editor (rest_for_one)

  A FileWatcher crash restarts only FileWatcher. A Watchdog crash restarts
  only Watchdog. Neither cascades into the Editor.Supervisor or each other.
  The tight Parser → Port → Editor cascade is handled internally by
  Editor.Supervisor's own `rest_for_one` strategy.

  This supervisor is conditionally started: it only appears in the tree
  when the editor UI is active (not in test mode or headless operation).
  """

  use Supervisor

  @typedoc "Options for starting the runtime supervisor."
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
      # Watchdog starts first so it's ready to receive SIGUSR1 from the
      # moment the Editor boots. It's an independent leaf: its crash
      # restarts only itself under one_for_one.
      Minga.Editor.Watchdog,
      # FileWatcher is a leaf: Editor receives messages from it but doesn't
      # depend on it structurally. A filesystem watcher flake restarts only
      # FileWatcher, not the renderer.
      Minga.FileWatcher,
      # Editor.Supervisor groups the tightly-coupled trio with rest_for_one:
      # Parser crash → Port + Editor restart, Port crash → Editor restart.
      {Minga.Editor.Supervisor, [backend: backend]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
