defmodule Minga.Application do
  @moduledoc """
  The Minga OTP Application.

  Starts the supervision tree (the "Stamm") that manages all editor
  processes. The top-level supervisor uses `rest_for_one` so that a
  Foundation crash cascades to Services and the Editor, but not the
  other way around.

  ## Supervision Tree

      Minga.Supervisor (rest_for_one)
      ├── MingaEditor.Shell.Registry         (serialized shell publication)
      ├── Minga.Foundation.Supervisor (rest_for_one)
      │   ├── Minga.Language.Registry
      │   ├── Minga.Extensions.LanguagePacks
      │   ├── Minga.Extensions.ThemePacks
      │   ├── Minga.Events (Registry, :duplicate)
      │   ├── Minga.Config.Options
      │   ├── Minga.Keymap.Active
      │   ├── Minga.Config.Hooks
      │   ├── Minga.Config.Advice
      │   └── Minga.Language.Filetype.Registry
      ├── Minga.Buffer.Registry (Registry, :unique)
      ├── Minga.Buffer.Supervisor (DynamicSupervisor, one_for_one)
      ├── Minga.Log.MessagesBuffer           (singleton *Messages* buffer owner)
      ├── Minga.Services.Supervisor (rest_for_one)
      │   ├── Minga.Services.Independent (one_for_one)
      │   │   ├── Minga.Git.Tracker
      │   │   ├── Minga.CommandOutput.Registry
      │   │   ├── Minga.Eval.TaskSupervisor
      │   │   ├── Minga.Command.Registry
      │   │   └── Minga.Diagnostics
      │   ├── Minga.Extension.Registry
      │   ├── MingaAgent.ProviderRegistry
      │   ├── MingaAgent.Hooks.Registry
      │   ├── MingaAgent.MCP.ServerRegistry
      │   ├── MingaAgent.Skills.Registry
      │   ├── MingaEditor.Agent.SlashCommand.Registry
      │   ├── Minga.Extension.Supervisor
      │   ├── Minga.Config.Loader
      │   ├── Minga.LSP.Supervisor
      │   ├── Minga.LSP.SyncServer
      │   └── Minga.Project
      ├── MingaAgent.Supervisor (DynamicSupervisor, one_for_one)
      ├── Minga.Runtime.Supervisor (one_for_one, conditional)
      │   ├── MingaEditor.Watchdog          (independent leaf)
      │   ├── Minga.FileWatcher              (independent leaf)
      │   └── MingaEditor.Supervisor (rest_for_one)
      │       ├── Minga.Parser.Manager
      │       ├── MingaEditor.Frontend.Manager
      │       ├── MingaEditor.Renderer.Server
      │       └── MingaEditor
      └── Minga.SystemObserver               (always-on process observer)

  In standalone Burrito mode, or when the macOS app's bundled TUI wrapper is
  used, automatically processes CLI arguments after the supervision tree is up.
  """

  use Application

  alias MingaAgent.SessionStore
  alias Minga.Config
  alias Minga.Telemetry.DevHandler
  alias Minga.Telemetry.StartupTimer
  alias Minga.Tool.Manager, as: ToolManager
  alias Minga.Language.Grammar

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    assert_expected_distribution_state!()

    # Info-only flags (--version/--help) must not boot the supervision tree.
    # Booting it spins up the event recorder, extensions, and watchdog just to
    # print a string, which can add seconds of startup. Short-circuit first.
    maybe_print_info_and_halt()
    maybe_prepare_cli_startup()

    StartupTimer.start()

    # Create the log buffer ETS table owned by the supervisor process.
    # This table survives process crashes so LoggerHandler can queue messages
    # before Minga.Log.MessagesBuffer subscribes and drains it on init.
    Minga.LoggerHandler.ensure_buffer_table()
    Grammar.init_registry()
    DevHandler.attach()
    Minga.Config.ThemeRegistry.seed_builtin()

    # Prepend managed tools bin directory to PATH so System.find_executable
    # discovers managed tools. Done before supervisors start so LSP and
    # formatter code can find tools immediately.
    tools_bin = ToolManager.bin_dir()
    File.mkdir_p!(tools_bin)
    current_path = System.get_env("PATH") || ""

    unless String.contains?(current_path, tools_bin) do
      System.put_env("PATH", "#{tools_bin}:#{current_path}")
    end

    # Install the :log_message broadcast handler before the supervision
    # tree starts so headless and pre-editor logs reach Minga.Log.MessagesBuffer
    # via the same path as logs from a running editor.
    Minga.LoggerHandler.install_messages_handler()
    store_startup_safe_mode()

    StartupTimer.mark(:pre_supervisor_setup)

    minimal? = minimal_mode?()

    base_children =
      [
        MingaEditor.Shell.Registry,
        Minga.Extension.CallbackRegistry,
        Minga.Foundation.Supervisor,
        {Registry, keys: :unique, name: Minga.Buffer.Registry},
        {DynamicSupervisor, name: Minga.Buffer.Supervisor, strategy: :one_for_one},
        Minga.Log.MessagesBuffer
      ] ++
        if minimal? do
          []
        else
          [Minga.Services.Supervisor, MingaAgent.Supervisor]
        end

    editor_children =
      if start_editor?() do
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

    # SystemObserver is last: it monitors all other supervisors and needs
    # the full tree to be up. With rest_for_one, its crash restarts nothing
    # (nothing comes after it), and any upstream crash restarts it too
    # (correct: re-establishes monitors).
    children = base_children ++ Enum.concat(editor_children, [Minga.SystemObserver])

    opts = [strategy: :rest_for_one, name: Minga.Supervisor]
    StartupTimer.mark(:children_built)
    result = Supervisor.start_link(children, opts)
    StartupTimer.mark(:supervision_tree_started)

    unless minimal? do
      if match?({:ok, _}, result) do
        Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, &prune_old_sessions/0)
      end
    end

    unless start_editor?() do
      StartupTimer.mark(:app_start_complete)
      StartupTimer.report()
    end

    if cli_boot?() and match?({:ok, _}, result) do
      if minimal? do
        Task.start_link(fn -> Minga.CLI.start_from_cli() end)
      else
        Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
          Minga.CLI.start_from_cli()
        end)
      end
    end

    result
  end

  @impl true
  @spec prep_stop(term()) :: term()
  def prep_stop(state) do
    Minga.Frontend.WaitRequests.accept_all()

    case Minga.Frontend.WaitRequests.await_acknowledgements(2_000) do
      :ok ->
        :ok

      {:error, :timeout} ->
        Minga.Log.warning(:editor, "Timed out waiting for native IPC completion acknowledgements")
    end

    state
  end

  @impl true
  @spec stop(term()) :: :ok
  def stop(_state) do
    # Mark the session as cleanly shut down so the next launch
    # knows this wasn't a crash.
    # Uses the default session dir (same as Editor.Supervisor). Application.stop
    # has no access to the Editor's runtime state, so it can't use an injected path.
    Minga.Session.mark_clean_shutdown()
    Minga.Remote.ControlEndpoint.clear_current_node()

    # Clean shutdown: restore the default console logger and stderr device.
    # This only runs when the application is stopping gracefully, not on
    # Editor crashes (where the LoggerHandler stays installed so crash
    # reports flow through the ETS buffer and get replayed on restart).
    Logger.flush()

    case :logger.get_handler_config(:minga_messages) do
      {:ok, _} -> Minga.LoggerHandler.uninstall()
      _ -> :ok
    end

    case Minga.DebugLog.stop() do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Failed to stop debug log during shutdown: #{inspect(reason)}")
    end

    :ok
  end

  @spec assert_expected_distribution_state!() :: :ok
  defp assert_expected_distribution_state! do
    case ensure_expected_distribution_state() do
      :ok ->
        :ok

      {:error, :unexpected_distribution} ->
        raise "refusing local GUI/TUI startup because Erlang distribution was enabled before application boot"
    end
  end

  @doc "Rejects inherited distribution for launch modes that explicitly require a local VM."
  @spec ensure_expected_distribution_state(boolean(), String.t() | nil) ::
          :ok | {:error, :unexpected_distribution}
  def ensure_expected_distribution_state(
        node_alive? \\ Node.alive?(),
        expectation \\ System.get_env("MINGA_EXPECT_DISTRIBUTION")
      )

  def ensure_expected_distribution_state(true, "0"), do: {:error, :unexpected_distribution}
  def ensure_expected_distribution_state(_node_alive?, _expectation), do: :ok

  @spec maybe_print_info_and_halt() :: :ok
  defp maybe_print_info_and_halt do
    if standalone_cli?() do
      case Minga.CLI.info_flag_output(Minga.CLI.argv()) do
        {:ok, message} ->
          IO.puts(message)
          System.halt(0)

        :none ->
          :ok
      end
    else
      :ok
    end
  rescue
    # Never let argument inspection break startup; fall through to normal boot,
    # but leave a breadcrumb in case this ever misfires.
    error ->
      Minga.Log.debug(:editor, "info-flag short-circuit skipped: #{inspect(error)}")
      :ok
  end

  @spec start_editor?() :: boolean()
  defp start_editor? do
    Application.get_env(:minga, :start_editor, false) or
      (Burrito.Util.running_standalone?() and not standalone_headless?() and
         not standalone_terminal_command?())
  end

  @spec maybe_prepare_cli_startup() :: :ok
  defp maybe_prepare_cli_startup do
    if cli_boot?() do
      Minga.CLI.prepare_startup(Minga.CLI.argv())
    else
      :ok
    end
  end

  @spec cli_boot?() :: boolean()
  defp cli_boot? do
    standalone_cli?() or System.get_env("MINGA_PORT_MODE") == "connected"
  end

  @spec standalone_cli?() :: boolean()
  defp standalone_cli? do
    Burrito.Util.running_standalone?() or System.get_env("MINGA_STANDALONE_TUI") == "1"
  end

  @spec minimal_mode?() :: boolean()
  defp minimal_mode? do
    Application.get_env(:minga, :minimal_mode, false) or standalone_minimal?()
  end

  @spec store_startup_safe_mode() :: :ok
  defp store_startup_safe_mode do
    if Minga.SafeMode.active?() do
      Minga.SafeMode.put(true)
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec standalone_headless?() :: boolean()
  defp standalone_headless? do
    Minga.CLI.headless_args?(Minga.CLI.argv())
  rescue
    error ->
      Minga.Log.debug(:editor, "Could not inspect standalone CLI args: #{inspect(error)}")
      false
  end

  @spec standalone_terminal_command?() :: boolean()
  defp standalone_terminal_command? do
    Minga.CLI.terminal_command?(Minga.CLI.argv())
  rescue
    error ->
      Minga.Log.debug(:editor, "Could not inspect standalone CLI args: #{inspect(error)}")
      false
  end

  @spec standalone_minimal?() :: boolean()
  defp standalone_minimal? do
    Minga.CLI.minimal_args?(Minga.CLI.argv())
  rescue
    _ -> false
  end

  @spec prune_old_sessions() :: :ok
  defp prune_old_sessions do
    retention_days = Config.get(:agent_session_retention_days)

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
