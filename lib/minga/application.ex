defmodule Minga.Application do
  @moduledoc """
  The Minga OTP Application.

  Starts the supervision tree (the "Stamm") that manages all editor
  processes. The top-level supervisor uses `rest_for_one` so that a
  Foundation crash cascades to Services and the Editor, but not the
  other way around.

  ## Supervision Tree

      Minga.Supervisor (rest_for_one)
      ├── Minga.Foundation.Supervisor (rest_for_one)
      │   ├── Minga.Language.Registry
      │   ├── Minga.Events (Registry, :duplicate)
      │   ├── Minga.Config.Options
      │   ├── Minga.Keymap.Active
      │   ├── Minga.Config.Hooks
      │   ├── Minga.Config.Advice
      │   └── Minga.Filetype.Registry
      ├── Minga.Buffer.Registry (Registry, :unique)
      ├── Minga.Buffer.Supervisor (DynamicSupervisor, one_for_one)
      ├── Minga.Services.Supervisor (rest_for_one)
      │   ├── Minga.Services.Independent (one_for_one)
      │   │   ├── Minga.Git.Tracker
      │   │   ├── Minga.CommandOutput.Registry
      │   │   ├── Minga.Eval.TaskSupervisor
      │   │   ├── Minga.Command.Registry
      │   │   ├── Minga.Fold.Registry
      │   │   └── Minga.Diagnostics
      │   ├── Minga.Extension.Registry
      │   ├── Minga.Extension.Supervisor
      │   ├── Minga.Config.Loader
      │   ├── Minga.LSP.Supervisor
      │   ├── Minga.LSP.SyncServer
      │   ├── Minga.Project
      │   └── Minga.Agent.Supervisor
      └── Minga.Runtime.Supervisor (one_for_one, conditional)
          ├── Minga.Editor.Watchdog          (independent leaf)
          ├── Minga.FileWatcher              (independent leaf)
          └── Minga.Editor.Supervisor (rest_for_one)
              ├── Minga.Parser.Manager
              ├── Minga.Port.Manager
              └── Minga.Editor

  In standalone (Burrito) mode, automatically processes CLI arguments
  after the supervision tree is up.
  """

  use Application

  alias Minga.Agent.SessionStore
  alias Minga.Config.Options
  alias Minga.Highlight.Grammar
  alias Minga.Telemetry.DevHandler
  alias Minga.Tool.Manager, as: ToolManager

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    # Create the log buffer ETS table owned by the supervisor process.
    # This table survives Editor crashes so the LoggerHandler can queue
    # messages while the Editor is restarting. The Editor flushes it on init.
    Minga.LoggerHandler.ensure_buffer_table()
    Grammar.init_registry()
    DevHandler.attach()

    # Prepend managed tools bin directory to PATH so System.find_executable
    # discovers managed tools. Done before supervisors start so LSP and
    # formatter code can find tools immediately.
    tools_bin = ToolManager.bin_dir()
    File.mkdir_p!(tools_bin)
    current_path = System.get_env("PATH") || ""

    unless String.contains?(current_path, tools_bin) do
      System.put_env("PATH", "#{tools_bin}:#{current_path}")
    end

    base_children = [
      Minga.Foundation.Supervisor,
      {Registry, keys: :unique, name: Minga.Buffer.Registry},
      {DynamicSupervisor, name: Minga.Buffer.Supervisor, strategy: :one_for_one},
      Minga.Services.Supervisor
    ]

    editor_children =
      if Application.get_env(:minga, :start_editor, false) or
           Burrito.Util.running_standalone?() do
        backend = Application.get_env(:minga, :backend, :tui)

        [
          # Runtime.Supervisor wraps Watchdog, FileWatcher, and Editor.Supervisor
          # under one_for_one so leaf processes restart independently. A FileWatcher
          # crash restarts only FileWatcher, not the renderer.
          {Minga.Runtime.Supervisor, [backend: backend]}
        ]
      else
        []
      end

    children = base_children ++ editor_children

    opts = [strategy: :rest_for_one, name: Minga.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Prune old agent sessions using the supervised Task.Supervisor
    # (not fire-and-forget Task.start) so crashes are visible.
    if match?({:ok, _}, result) do
      Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, &prune_old_sessions/0)
    end

    # In Burrito standalone mode, kick off the CLI
    if Burrito.Util.running_standalone?() do
      Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
        Minga.CLI.start_from_cli()
      end)
    end

    result
  end

  @impl true
  @spec stop(term()) :: :ok
  def stop(_state) do
    # Mark the session as cleanly shut down so the next launch
    # knows this wasn't a crash.
    # Uses the default session dir (same as Editor.Supervisor). Application.stop
    # has no access to the Editor's runtime state, so it can't use an injected path.
    Minga.Session.mark_clean_shutdown()

    # Clean shutdown: restore the default console logger and stderr device.
    # This only runs when the application is stopping gracefully, not on
    # Editor crashes (where the LoggerHandler stays installed so crash
    # reports flow through the ETS buffer and get replayed on restart).
    case :logger.get_handler_config(:minga_messages) do
      {:ok, _} -> Minga.LoggerHandler.uninstall()
      _ -> :ok
    end

    :ok
  end

  @spec prune_old_sessions() :: :ok
  defp prune_old_sessions do
    retention_days = Options.get(:agent_session_retention_days)

    pruned = SessionStore.prune(retention_days)

    if pruned > 0 do
      Minga.Log.info(
        :agent,
        "[Agent] pruned #{pruned} sessions older than #{retention_days} days"
      )
    end

    :ok
  end
end
