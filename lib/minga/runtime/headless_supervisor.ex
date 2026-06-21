defmodule Minga.Runtime.HeadlessSupervisor do
  @moduledoc """
  Supervises the node-shared deps a headless daemon needs to host attached
  client editor sessions (collab MVP, #2424).

      Runtime.HeadlessSupervisor (one_for_one)
      ├── Minga.Parser.Manager               Tree-sitter parser Port (node-shared)
      └── MingaEditor.Collab.SessionManager   DynamicSupervisor for per-session triads

  A real `minga --headless` daemon does not start the interactive editor runtime
  (`Minga.Runtime.Supervisor` is gated by `start_editor?/0`, which is false for
  the daemon). But `MingaEditor.Collab.attach/4` still needs to stand up a
  per-client editor triad via `MingaEditor.Collab.SessionManager`, and each such
  editor subscribes to the node-shared `Minga.Parser.Manager` for syntax
  highlighting. Without this supervisor those processes are absent, so an attach
  would fail with `:noproc`.

  This is intentionally a thin subset of `Minga.Runtime.Supervisor`:

  - It starts *only* the session-hosting `DynamicSupervisor` and the shared
    parser. It does **not** start the default interactive triad
    (`MingaEditor.Collab.SessionSupervisor`), the watchdog, or the file watcher;
    a daemon has no local frontend to drive and hosts sessions only on attach.
  - The buffer registries (`Minga.Buffer.Registry`,
    `Minga.Buffer.Supervisor`) and the per-session naming registry
    (`MingaEditor.Collab.Registry`) are started unconditionally in
    `Minga.Application`'s base children, so they are already available headless
    and are not duplicated here.

  `one_for_one` so a parser crash restarts only the parser (attached editors
  re-subscribe on its `:DOWN`; see `MingaEditor.handle_info/2`) and a
  SessionManager crash restarts only the session supervisor.
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
      # Node-shared parser Port. Each attached client's editor subscribes to it
      # for highlight events and re-subscribes if it restarts.
      Minga.Parser.Manager,
      # DynamicSupervisor that hosts the per-client editor triads started on
      # attach by MingaEditor.Collab.attach/4.
      MingaEditor.Collab.SessionManager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
