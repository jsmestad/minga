defmodule MingaEditor do
  @moduledoc """
  Editor orchestration GenServer.

  Ties together the buffer, port manager, viewport, and modal FSM. Receives
  input events from the Port Manager, routes them through `Minga.Mode.process/3`,
  executes the resulting commands against the buffer, recomputes the visible
  region, and sends render commands back to the Zig renderer.

  The editor starts in **Normal mode** (Vim-style). The status line reflects
  the current mode: `-- NORMAL --`, `-- INSERT --`, etc.
  """

  use GenServer

  alias MingaEditor.Agent.Events
  alias MingaEditor.Agent.UIState
  alias Minga.Buffer
  alias Minga.Config
  alias Minga.Editing.Completion
  alias Minga.FileRef
  alias Minga.Git

  alias Minga.Diagnostics.Decorations, as: DiagDecorations
  alias Minga.Session

  alias MingaEditor.AgentLifecycle
  alias MingaEditor.BottomPanel

  alias MingaEditor.Commands
  alias MingaEditor.CompletionHandling
  alias MingaEditor.FileWatcherHelpers
  alias MingaEditor.HighlightEvents
  alias MingaEditor.HighlightSync
  alias MingaEditor.KeyDispatch
  alias MingaEditor.Layout
  alias MingaEditor.InlineAsk.Events, as: InlineAskEvents
  alias MingaEditor.InlineEdit.Events, as: InlineEditEvents
  alias MingaEditor.LspActions
  alias MingaEditor.MessageLog
  alias MingaEditor.NavFlash
  alias MingaEditor.YankFlash
  alias MingaEditor.Renderer
  alias MingaEditor.SemanticTokenSync
  alias MingaEditor.Startup
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.ResourcePressure
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport

  alias MingaEditor.Handlers.EventDispatcher
  alias MingaEditor.Handlers.FileEventHandler
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Handlers.HighlightHandler
  alias MingaEditor.Handlers.LspEventHandler
  alias MingaEditor.Handlers.SessionHandler
  alias MingaEditor.Handlers.ToolHandler
  # WarningLog removed in #825; warnings route through MessageLog with level override
  alias MingaEditor.Window
  alias MingaEditor.Input
  alias Minga.LSP.SyncServer, as: LspSyncServer
  alias Minga.Mode
  alias Minga.Project.FileTree
  # PopupLifecycle alias removed: warnings popup replaced by bottom panel (#825)

  @typedoc "Options for starting the editor."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:backend, MingaEditor.State.backend()}
          | {:port_manager, GenServer.server()}
          | {:parser_manager, GenServer.server()}
          | {:keymap_server, GenServer.server()}
          | {:options_server, GenServer.server() | nil}
          | {:events_registry, Minga.Events.registry()}
          | {:buffer, pid()}
          | {:width, pos_integer()}
          | {:height, pos_integer()}
          | {:editing_model, :vim | :cua}
          | {:shell, :traditional | :board | module()}
          | {:project_root, String.t() | nil}
          | {:swap_dir, String.t()}
          | {:session_dir, String.t()}
          | {:suppress_tool_prompts, boolean()}

  alias MingaEditor.State, as: EditorState

  alias MingaEditor.State.Session, as: EditorSessionState

  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab.Context, as: TabContext

  alias MingaEditor.MouseHoverTooltip
  alias MingaEditor.PickerUI
  alias MingaEditor.UI.Notification

  @typedoc "Internal state."
  @type state :: EditorState.t()

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the editor."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Opens a file in the editor."
  @spec open_file(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def open_file(server \\ __MODULE__, file_path) when is_binary(file_path) do
    GenServer.call(server, {:open_file, file_path})
  end

  @doc "Triggers a full re-render of the current state."
  @spec render(GenServer.server()) :: :ok
  def render(server \\ __MODULE__) do
    GenServer.cast(server, :render)
  end

  @doc "Log a message to the *Messages* buffer. Used by the custom Logger handler."
  @spec log_to_messages(String.t(), GenServer.server()) :: :ok
  def log_to_messages(text, server \\ __MODULE__) do
    # Use cast (not call) to avoid deadlocking when Logger is invoked from
    # inside the Editor GenServer itself.
    GenServer.cast(server, {:log_to_messages, text})
  end

  @doc """
  Log a warning/error to the *Warnings* buffer with auto-popup.

  Used by the custom Logger handler. The popup opens without stealing
  focus. Once the user dismisses it with `q`, new warnings are logged
  silently until the user explicitly re-opens via `SPC b W`.
  """
  @spec log_to_warnings(String.t(), GenServer.server()) :: :ok
  def log_to_warnings(text, server \\ __MODULE__) do
    GenServer.cast(server, {:log_to_warnings, text})
  end

  @doc """
  Ensures a buffer exists for the given file path, opening one if needed.

  Delegates to the Editor GenServer so it can use the editor's options server
  for buffer creation, then registers the buffer in the workspace (buffer list,
  monitoring, log message). The buffer is added in the background without
  switching the active window.

  Layer 2 callers that need workspace registration should use this function.
  Layer 1 callers (agent tools) should use `Buffer.ensure_for_path/1` directly.
  """
  @spec ensure_buffer_for_path(String.t(), GenServer.server()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_buffer_for_path(path, server \\ __MODULE__) do
    case live_editor_server(server) do
      nil -> Buffer.ensure_for_path(path)
      live_server -> ensure_buffer_for_path_via_editor(path, live_server)
    end
  end

  @spec live_editor_server(GenServer.server()) :: pid() | nil
  defp live_editor_server(server) when is_pid(server) do
    if Process.alive?(server), do: server, else: nil
  end

  defp live_editor_server(server), do: GenServer.whereis(server)

  @spec ensure_buffer_for_path_via_editor(String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  defp ensure_buffer_for_path_via_editor(path, live_server) do
    GenServer.call(live_server, {:ensure_buffer_for_path, path})
  catch
    :exit, reason -> handle_ensure_buffer_call_exit(reason, path)
  end

  @spec handle_ensure_buffer_call_exit(term(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp handle_ensure_buffer_call_exit(reason, path) do
    if stale_editor_call_exit?(reason) do
      Buffer.ensure_for_path(path)
    else
      exit(reason)
    end
  end

  @spec stale_editor_call_exit?(term()) :: boolean()
  defp stale_editor_call_exit?({reason, {GenServer, :call, _args}}),
    do: reason in [:noproc, :normal, :shutdown] or match?({:shutdown, _}, reason)

  defp stale_editor_call_exit?(reason), do: reason in [:noproc, :normal, :shutdown]

  @doc "Send an async message to the Editor GenServer. Used by background tasks."
  @spec cast(term(), GenServer.server()) :: :ok
  def cast(msg, server \\ __MODULE__) do
    GenServer.cast(server, msg)
  end

  # ── Server Callbacks ─────────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    # Tune GC for the Editor process: frequent full sweeps reclaim binary
    # refs from the render loop, and a larger initial heap avoids repeated
    # grow-and-GC cycles during startup.
    Process.flag(:fullsweep_after, 20)
    Process.flag(:min_heap_size, 4096)

    state = Startup.build_initial_state(opts)

    renderer_pid = renderer_pid_for_backend(state.backend)

    if state.backend != :headless and is_nil(renderer_pid) do
      Minga.Log.warning(:editor, "Renderer.Server not found at init; rendering synchronously")
    end

    state = EditorState.set_renderer(state, renderer_pid)

    # Logger redirect and startup messages
    state =
      if state.backend != :headless do
        log_path = Minga.LoggerHandler.install()
        state = log_message(state, "Editor started")
        log_message(state, "Log file: #{log_path}")
      else
        log_message(state, "Editor started")
      end

    state = Startup.apply_config_options(state)
    events_registry = EditorState.events_registry(state)
    Minga.Events.subscribe(:diagnostics_updated, events_registry)
    Minga.Events.subscribe(:lsp_status_changed, events_registry)

    # Refresh file tree state when buffers, project files, git, diagnostics, or project roots change.
    Minga.Events.subscribe(:buffer_saved, events_registry)
    Minga.Events.subscribe(:buffer_changed, events_registry)
    Minga.Events.subscribe(:file_written, events_registry)
    Minga.Events.subscribe(:project_rebuilt, events_registry)
    Minga.Events.subscribe(:git_status_changed, events_registry)
    Minga.Events.subscribe(:command_done, events_registry)

    # Tool manager progress: show install/update status in the status line.
    Minga.Events.subscribe(:tool_install_started, events_registry)
    Minga.Events.subscribe(:tool_install_progress, events_registry)
    Minga.Events.subscribe(:tool_install_complete, events_registry)
    Minga.Events.subscribe(:tool_install_failed, events_registry)
    Minga.Events.subscribe(:tool_uninstall_complete, events_registry)
    Minga.Events.subscribe(:tool_missing, events_registry)
    Minga.Events.subscribe(:log_message, events_registry)
    Minga.Events.subscribe(:face_overrides_changed, events_registry)
    Minga.Events.subscribe(:agent_session_stopped, events_registry)
    Minga.Events.subscribe(:background_subagent_started, events_registry)
    Minga.Events.subscribe(:node_connected, events_registry)
    Minga.Events.subscribe(:node_disconnected, events_registry)
    Minga.Events.subscribe(:load_user_themes, events_registry)
    Minga.Events.subscribe(:option_changed, events_registry)
    Minga.Events.subscribe(:extension_updates_available, events_registry)

    # Monitor all initial buffers so we get :DOWN when they die.
    all_initial_pids =
      state.workspace.buffers.list ++
        Enum.filter(
          [state.workspace.buffers.messages, state.workspace.buffers.help],
          &is_pid/1
        )

    state = EditorState.monitor_buffers(state, all_initial_pids)

    # Schedule periodic eviction of inactive tree-sitter parse trees.
    if state.backend != :headless do
      Process.send_after(self(), :evict_parser_trees, HighlightSync.eviction_check_interval_ms())
    end

    # Set up tree-sitter markdown highlighting for the agent buffer
    # so it's ready before the first sync. Idempotent: also called from
    # create_agent_buffer and ensure_agent_session, so whichever path
    # creates the buffer first wins and subsequent calls are no-ops
    # (ensure_buffer_id_for returns the existing ID, and set_language +
    # parse_buffer are idempotent on the Zig side).
    state = AgentLifecycle.setup_agent_highlight(state)

    {:ok, state}
  end

  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, _state) do
    # Do NOT uninstall the LoggerHandler here. OTP emits crash reports
    # AFTER terminate returns, so uninstalling would restore the default
    # stderr handler and the crash report would corrupt the TUI. The
    # LoggerHandler stays installed across Editor restarts; its ETS buffer
    # captures crash reports and flush_buffer/0 replays them on the next
    # init. Cleanup happens in Application.stop/1 (clean shutdown only).
    :ok
  end

  @spec renderer_pid_for_backend(EditorState.backend()) :: pid() | nil
  defp renderer_pid_for_backend(:headless), do: nil
  defp renderer_pid_for_backend(_backend), do: GenServer.whereis(MingaEditor.Renderer.Server)

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:open_file, file_path}, _from, state) do
    case open_file_by_path_result(state, file_path) do
      {:ok, new_state} ->
        new_state = Renderer.render_or_async(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ensure_buffer_for_path, path}, _from, state) do
    case Buffer.ensure_for_path(path, EditorState.events_registry(state),
           options_server: EditorState.options_server(state)
         ) do
      {:ok, pid} ->
        new_state =
          if buffer_tracked?(state, pid) do
            state
          else
            register_buffer_background(state, pid, Path.expand(path))
          end

        {:reply, {:ok, pid}, new_state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:api_active_buffer, _from, %{workspace: %{buffers: %{active: nil}}} = state) do
    {:reply, {:error, :no_buffer}, state}
  end

  def handle_call(:api_active_buffer, _from, %{workspace: %{buffers: %{active: buf}}} = state) do
    {:reply, {:ok, buf}, state}
  end

  def handle_call(:api_mode, _from, state) do
    {:reply, Minga.Editing.mode(state), state}
  end

  def handle_call(:api_save, _from, %{workspace: %{buffers: %{active: nil}}} = state) do
    {:reply, {:error, :no_buffer}, state}
  end

  def handle_call(:api_save, _from, %{workspace: %{buffers: %{active: buf}}} = state) do
    result = Buffer.save(buf)

    new_state =
      case result do
        :ok ->
          log_message(state, "Saved: #{Commands.Helpers.buffer_display_name(buf)}")

        _ ->
          state
      end

    new_state = Renderer.render_or_async(new_state)
    {:reply, result, new_state}
  end

  def handle_call({:api_execute_command, cmd}, _from, state) do
    new_state = dispatch_command(state, cmd)
    new_state = Renderer.render_or_async(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:api_set_fold_ranges, ranges}, _from, state) do
    new_state =
      case EditorState.active_window_struct(state) do
        nil ->
          state

        %Window{id: id} ->
          EditorState.update_window(state, id, &Window.set_fold_ranges(&1, ranges))
      end

    new_state = Renderer.render_or_async(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:api_log_message, text}, _from, state) do
    new_state = log_message(state, text)
    {:reply, :ok, new_state}
  end

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:register_background_buffer, pid, abs_path}, state) do
    # Register a buffer that was started by Buffer.ensure_for_path (called
    # from agent tools or Editor.ensure_buffer_for_path). Only register if
    # the buffer isn't already tracked in the workspace.
    already_tracked? = buffer_tracked?(state, pid)

    if already_tracked? do
      {:noreply, state}
    else
      state = register_buffer_background(state, pid, abs_path)
      {:noreply, state}
    end
  end

  def handle_cast({:log_to_messages, text}, state) do
    {:noreply, log_message(state, text)}
  end

  def handle_cast({:log_to_warnings, text}, state) do
    state = MessageLog.log(state, text, :warning)
    {:noreply, maybe_schedule_warning_popup(state)}
  end

  def handle_cast(:render, state) do
    state = Renderer.render_or_async(state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:minga_input, {:ready, width, height}}, state) do
    # Query capabilities from the frontend (may have been sent in extended ready).
    caps = Startup.fetch_capabilities(state.port_manager)
    Startup.apply_gui_defaults(caps, EditorState.options_server(state))

    line_spacing = Config.get(:line_spacing) || 1.0
    effective_height = Viewport.effective_rows(height, line_spacing)

    vp = Viewport.new(effective_height, width)

    new_state = %{
      (state
       |> EditorState.set_terminal_viewport(vp)
       |> EditorState.set_viewport(vp))
      | capabilities: caps,
        layout: nil
    }

    Startup.send_font_config(new_state)
    push_full_config_state(new_state)
    new_state = Renderer.render_or_async(new_state)
    # Setup highlighting after first paint with correct viewport
    new_state = setup_highlight_or_defer(new_state)

    maybe_check_swap_recovery(new_state)

    # If the agentic view was activated at init, start the session now
    # that the port is connected and the viewport is known.
    new_state = AgentLifecycle.maybe_start_session(new_state)
    # Start the periodic session save timer (30 seconds); skip in headless
    # to avoid non-deterministic timer messages during tests.
    new_state =
      if new_state.backend != :headless do
        %{new_state | session: EditorSessionState.start_timer(new_state.session)}
      else
        new_state
      end

    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:capabilities_updated, caps}}, state) do
    new_state = %{state | capabilities: caps}

    new_state =
      log_message(
        new_state,
        "Frontend capabilities updated: #{inspect(caps.frontend_type)}, color: #{inspect(caps.color_depth)}"
      )

    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:resize, width, height}}, state) do
    line_spacing = Config.get(:line_spacing) || 1.0
    effective_height = Viewport.effective_rows(height, line_spacing)

    vp = Viewport.new(effective_height, width)

    new_state =
      state
      |> EditorState.set_terminal_viewport(vp)
      |> EditorState.set_viewport(vp)

    # Invalidate the cached layout so resize_all_windows computes fresh
    # rectangles from the new viewport dimensions.
    new_state = Layout.invalidate(new_state)
    new_state = resize_all_windows(new_state)
    new_state = Renderer.render_or_async(new_state)
    {:noreply, new_state}
  end

  # ── Key press dispatch ──
  # All key presses go through the focus stack via Input.Router.
  # The router walks ConflictPrompt → Picker → Completion → GlobalBindings → ModeFSM
  # and runs centralized post-key housekeeping (highlight sync, reparse,
  # completion, render) exactly once.
  def handle_info({:minga_input, {:key_press, codepoint, modifiers}}, state) do
    state = cancel_nav_flash(state)
    state = cancel_yank_flash(state)

    new_state =
      Minga.Telemetry.span([:minga, :input, :dispatch], %{}, fn ->
        Input.Router.dispatch(state, codepoint, modifiers)
      end)

    {:noreply, new_state}
  end

  # ── Paste event (bracketed paste from TUI, Cmd+V from GUI) ──
  def handle_info({:minga_input, {:paste_event, text}}, state) do
    new_state = handle_paste_event(state, text)
    new_state = Renderer.render_or_async(new_state)
    {:noreply, new_state}
  end

  # ── File watcher notification ──
  def handle_info({:file_changed_on_disk, path} = msg, state) do
    new_state = FileWatcherHelpers.handle_file_change(state, path)
    new_state = log_message(new_state, "External change detected: #{path}")
    {new_state, effects} = FileEventHandler.handle(new_state, msg)
    {:noreply, apply_effects(new_state, effects)}
  end

  def handle_info(
        {:minga_input, {:mouse_event, row, col, button, mods, event_type, click_count}},
        state
      ) do
    snapshot = Input.Router.capture_snapshot(state)

    new_state =
      Input.Router.dispatch_mouse(state, row, col, button, mods, event_type, click_count)

    new_state = Input.Router.post_action_housekeeping(new_state, snapshot)
    {:noreply, new_state}
  end

  # Backward compat: 6-element mouse_event (no click_count)
  def handle_info(
        {:minga_input, {:mouse_event, row, col, button, mods, event_type}},
        state
      ) do
    snapshot = Input.Router.capture_snapshot(state)
    new_state = Input.Router.dispatch_mouse(state, row, col, button, mods, event_type, 1)
    new_state = Input.Router.post_action_housekeeping(new_state, snapshot)
    {:noreply, new_state}
  end

  # ── GUI action events (semantic commands from SwiftUI chrome) ────────────

  def handle_info({:minga_input, {:gui_action, action}}, state) do
    snapshot = Input.Router.capture_snapshot(state)
    new_state = GuiActionHandler.dispatch(state, action)
    new_state = Input.Router.post_action_housekeeping(new_state, snapshot)
    {:noreply, new_state}
  end

  def handle_info({:whichkey_timeout, ref}, state) do
    if ref == state.shell_state.whichkey.timer do
      wk = EditorState.whichkey(state)
      new_state = EditorState.set_whichkey(state, %{wk | show: true})
      {:noreply, Renderer.render_or_async(new_state)}
    else
      # Stale timer — ignore.
      {:noreply, state}
    end
  end

  # ── TUI SPC leader timeout ──────────────────────────────────────────────

  def handle_info(:space_leader_timeout, state) do
    new_state = MingaEditor.Input.CUA.TUISpaceLeader.handle_timeout(state)
    {:noreply, new_state}
  end

  # ── Handler-delegated bare atom events ─────────────────────────────────────
  # Bare atom messages routed to HighlightHandler, SessionHandler, or
  # ToolHandler via a module attribute map (guard-safe via is_map_key/2).

  @handler_atom_dispatch %{
    setup_highlight: HighlightHandler,
    evict_parser_trees: HighlightHandler,
    check_swap_recovery: SessionHandler,
    save_session: SessionHandler,
    clear_tool_status: ToolHandler
  }

  def handle_info(msg, state) when is_map_key(@handler_atom_dispatch, msg) do
    handler = @handler_atom_dispatch[msg]
    {state, effects} = handler.handle(state, msg)
    {:noreply, apply_effects(state, effects)}
  end

  # ── Highlight events from Parser.Manager ──────────────────────────────────────
  # These arrive as {:minga_highlight, event} from the dedicated parser process.
  # Legacy {:minga_input, event} forms are also accepted for backward
  # compatibility during the transition (headless tests, etc.).
  # Log messages from the renderer port also arrive via {:minga_input, {:log_message, ...}}.
  # All {:minga_highlight, _} messages go straight to HighlightHandler.

  def handle_info({:minga_highlight, _} = msg, state) do
    {state, effects} = HighlightHandler.handle(state, msg)
    {:noreply, apply_effects(state, effects)}
  end

  # Remaining {:minga_input, _} messages are highlight/parser events forwarded
  # via the legacy input tag. All input-specific :minga_input clauses (ready,
  # resize, key_press, paste_event, mouse_event, gui_action,
  # capabilities_updated) are matched above, so this catch-all is safe.
  def handle_info({:minga_input, _} = msg, state) do
    {state, effects} = HighlightHandler.handle(state, msg)
    {:noreply, apply_effects(state, effects)}
  end

  # LSP/completion timer events routed through a focused handler.
  def handle_info({:completion_debounce, _clients, _buffer_pid} = msg, state) do
    {state, effects} = LspEventHandler.handle(state, msg)
    {:noreply, apply_effects(state, effects)}
  end

  def handle_info({:lsp_response, _ref, _result} = msg, state) do
    {state, effects} = LspEventHandler.handle(state, msg)
    {:noreply, apply_effects(state, effects)}
  end

  @lsp_debounce_atoms [:inlay_hint_scroll_debounce, :document_highlight_debounce]

  def handle_info(msg, state) when msg in @lsp_debounce_atoms do
    {state, effects} = LspEventHandler.handle(state, msg)
    {:noreply, apply_effects(state, effects)}
  end

  def handle_info({:completion_resolve, _index} = msg, state) do
    {state, effects} = LspEventHandler.handle(state, msg)
    {:noreply, apply_effects(state, effects)}
  end

  def handle_info(:request_code_lens_and_inlay_hints = msg, state) do
    {state, effects} = LspEventHandler.handle(state, msg)
    {:noreply, apply_effects(state, effects)}
  end

  # ── Event bus messages ────────────────────────────────────────────────────────
  # All {:minga_event, event, payload} messages are routed through a single
  # catch-all to the appropriate handler or inline logic. This replaces 10
  # individual thin router clauses (LSP, diagnostics, tool, file events).
  def handle_info({:minga_event, event, payload} = msg, state) do
    {:noreply, EventDispatcher.dispatch(state, event, payload, msg)}
  end

  # Debounced render timer fired — perform the actual render.
  def handle_info(:debounced_render, state) do
    state = maybe_trigger_nav_flash(state)
    state = Renderer.render_or_async(state)
    {:noreply, %{state | render_timer: nil}}
  end

  # Debounced file-tree refresh timer fired — rescan the cached tree once for a burst of filesystem events.
  def handle_info(:file_tree_refresh_timer, state) do
    {state, effects} = FileEventHandler.handle(state, :file_tree_refresh_timer)
    {:noreply, apply_effects(state, effects)}
  end

  # Renderer.Server writeback after each async frame completes.
  # EditorState narrows the merge to renderer-owned fields only.
  def handle_info({:render_done, %{caches: _caches, layout: _layout} = wb}, state) do
    {:noreply, EditorState.apply_renderer_writeback(state, wb)}
  end

  # Nav-flash timer step — advance the fade or clear the flash.
  def handle_info(:nav_flash_step, state) do
    case state.shell_state.nav_flash do
      nil ->
        {:noreply, state}

      flash ->
        case NavFlash.advance(flash) do
          {:continue, updated, effects} ->
            state = EditorState.set_nav_flash(state, apply_flash_effects(state, updated, effects))
            {:noreply, Renderer.render_or_async(state)}

          :done ->
            {:noreply, Renderer.render_or_async(EditorState.cancel_nav_flash(state))}
        end
    end
  end

  # Yank-flash timer step — advance the fade or clear the flash.
  def handle_info(:yank_flash_step, state) do
    case state.shell_state.yank_flash do
      nil ->
        {:noreply, state}

      %YankFlash{buf: buf} = flash ->
        case YankFlash.advance(flash) do
          {:continue, updated, effects} ->
            update_yank_flash_decoration(buf, updated, state)
            updated = apply_flash_effects(state, updated, effects)
            state = EditorState.set_yank_flash(state, updated)
            {:noreply, Renderer.render_or_async(state)}

          :done ->
            clear_yank_highlight(buf)
            {:noreply, Renderer.render_or_async(EditorState.cancel_yank_flash(state))}
        end
    end
  end

  # Warning popup debounce timer fired — open the *Warnings* popup if not
  # already visible.
  def handle_info(:warning_popup_timeout, state) do
    state = EditorState.update_shell_state(state, &%{&1 | warning_popup_timer: nil})
    {:noreply, open_warnings_popup_if_needed(state)}
  end

  # ── Agent events ──────────────────────────────────────────────────────────
  #
  # All agent events are tagged with the session pid so we can route them
  # Agent events are handled directly via Agent.Events, which reads and
  # writes agent/agentic fields on EditorState directly.

  def handle_info({:agent_event, session_pid, event}, state) do
    Minga.Log.debug(:agent, "[event] #{inspect(event)}")
    route_agent_event(state, session_pid, event)
  end

  def handle_info({:inline_ask_prompt_sent, session_pid, result}, state) do
    state = InlineAskEvents.handle_prompt_result(state, session_pid, result)
    {:noreply, schedule_render(state, 16)}
  end

  def handle_info({:inline_edit_prompt_sent, session_pid, result}, state) do
    state = InlineEditEvents.handle_prompt_result(state, session_pid, result)
    {:noreply, schedule_render(state, 16)}
  end

  def handle_info(:agent_spinner_tick, state) do
    state = dispatch_agent_event(state, :spinner_tick)
    {:noreply, state}
  end

  # Process died. Check buffer monitors and git remote tasks.
  # Agent session deaths are handled via :agent_session_stopped events from SessionManager.
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case classify_down(state, ref, pid, reason) do
      :buffer ->
        Minga.Log.info(:editor, "Buffer process #{inspect(pid)} died, removing from state")
        state = EditorState.remove_dead_buffer(state, pid)
        {:noreply, Renderer.render_or_async(state)}

      {:git_remote_task, updated_state} ->
        {:noreply, Renderer.render_or_async(updated_state)}

      :unknown ->
        {:noreply, state}
    end
  end

  @toast_duration_ms 3_000

  # Mouse hover timeout: check if the mouse is over a diagnostic or symbol
  def handle_info(:mouse_hover_timeout, state) do
    state = MouseHoverTooltip.check_hover(state)
    {:noreply, Renderer.render_or_async(state)}
  end

  def handle_info(:dismiss_toast, state) do
    state = dispatch_agent_event(state, :dismiss_toast)

    if UIState.toast_visible?(AgentAccess.agent_ui(state)) and state.backend != :headless do
      Process.send_after(self(), :dismiss_toast, @toast_duration_ms)
    end

    {:noreply, state}
  end

  def handle_info({:dismiss_git_toast, dismiss_ref}, state) do
    state = EditorState.clear_git_toast(state, dismiss_ref)
    {:noreply, Renderer.render_or_async(state)}
  end

  def handle_info({:dismiss_notification, id, dismiss_ref}, state) do
    state = EditorState.dismiss_notification(state, id, dismiss_ref)
    {:noreply, Renderer.render_or_async(state)}
  end

  # ── AI commit message generation ───────────────────────────────────────────

  def handle_info({:git_commit_message_generated, {:ok, message}}, state) do
    state = %{state | git_commit_gen_ref: nil}

    state =
      if MingaEditor.State.ModalOverlay.active?(EditorState.modal(state)) do
        EditorState.set_status(state, "Commit message ready (prompt already open)")
      else
        state
        |> MingaEditor.PromptUI.open(MingaEditor.UI.Prompt.GitCommit, default: message)
        |> EditorState.set_status("Commit message generated")
      end

    {:noreply, Renderer.render_or_async(state)}
  end

  def handle_info({:git_commit_message_generated, {:error, reason}}, state) do
    state = %{state | git_commit_gen_ref: nil}
    state = EditorState.set_status(state, reason)
    {:noreply, Renderer.render_or_async(state)}
  end

  def handle_info(:git_generate_timeout, %{git_commit_gen_ref: ref} = state)
      when ref != nil do
    state = %{state | git_commit_gen_ref: nil}
    state = EditorState.set_status(state, "Commit message generation timed out")
    {:noreply, Renderer.render_or_async(state)}
  end

  def handle_info(:git_generate_timeout, state) do
    {:noreply, state}
  end

  # ── File/git events (delegated to FileEventHandler) ─────────────────────────

  def handle_info({:git_remote_result, ref, _result} = msg, state) when is_reference(ref) do
    {state, effects} = FileEventHandler.handle(state, msg)
    {:noreply, apply_effects(state, effects)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # In headless mode, apply highlight setup synchronously so tests get
  # deterministic highlights without timer races. In normal mode, defer
  # via a self-send so the first paint isn't blocked.
  @spec setup_highlight_or_defer(state()) :: state()
  defp setup_highlight_or_defer(%{backend: :headless} = state) do
    state = HighlightSync.setup_for_buffer(state)
    SemanticTokenSync.request_tokens(state)
  end

  defp setup_highlight_or_defer(state) do
    send(self(), :setup_highlight)
    state
  end

  # ── :DOWN classifier ────────────────────────────────────────────────────────

  @spec classify_down(EditorState.t(), reference(), pid(), term()) ::
          :buffer | {:git_remote_task, EditorState.t()} | :unknown
  defp classify_down(state, ref, pid, reason) do
    if Map.has_key?(state.buffer_monitors, pid) do
      :buffer
    else
      case Commands.Git.handle_remote_task_down(state, ref, reason) do
        :not_matched -> :unknown
        updated_state -> {:git_remote_task, updated_state}
      end
    end
  end

  @doc false
  @spec push_full_config_state(EditorState.t()) :: :ok
  def push_full_config_state(%{port_manager: nil}), do: :ok

  def push_full_config_state(%{port_manager: port} = state) do
    if MingaEditor.Frontend.gui?(state.capabilities) do
      config_state =
        MingaEditor.Frontend.Protocol.GUI.config_state(
          EditorState.options_server(state),
          state.keymap_server
        )

      MingaEditor.Frontend.send_config_state(port, config_state)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec push_config_state_entry(EditorState.t(), atom(), term()) :: EditorState.t()
  def push_config_state_entry(%{port_manager: nil} = state, _name, _value), do: state

  def push_config_state_entry(%{port_manager: port} = state, name, value) do
    if MingaEditor.Frontend.gui?(state.capabilities) and
         MingaEditor.Frontend.Protocol.GUI.settings_option?(name) do
      config_state = MingaEditor.Frontend.Protocol.GUI.config_state_entry(name, value)
      MingaEditor.Frontend.send_config_state(port, config_state)
    end

    state
  catch
    :exit, _ -> state
  end

  @doc false
  @spec apply_runtime_config_option(EditorState.t(), atom(), term()) :: EditorState.t()
  def apply_runtime_config_option(state, :theme, theme_name) when is_atom(theme_name) do
    case MingaEditor.UI.Theme.get(theme_name) do
      {:ok, theme} ->
        if state.port_manager do
          MingaEditor.Frontend.send_commands(state.port_manager, [
            MingaEditor.Frontend.Protocol.GUI.encode_gui_theme(theme)
          ])
        end

        %{state | theme: theme}
        |> EditorState.invalidate_all_windows()
        |> Layout.invalidate()

      :error ->
        state
    end
  catch
    :exit, _ -> state
  end

  def apply_runtime_config_option(state, name, _value)
      when name in [:font_family, :font_size, :font_weight, :font_ligatures] do
    Startup.send_font_config(state)
    state
  end

  def apply_runtime_config_option(state, name, value)
      when name in [:line_numbers, :wrap, :tab_width] do
    Enum.each(runtime_config_buffers(state), fn buffer ->
      Buffer.set_option(buffer, name, value)
    end)

    state
    |> EditorState.invalidate_all_windows()
    |> Layout.invalidate()
  end

  def apply_runtime_config_option(state, :cursorline, _value) do
    state
    |> EditorState.invalidate_all_windows()
    |> Layout.invalidate()
  end

  def apply_runtime_config_option(state, _name, _value), do: state

  @spec runtime_config_buffers(EditorState.t()) :: [pid()]
  defp runtime_config_buffers(state) do
    state.workspace.buffers.list
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  # ── LSP response dispatch ──────────────────────────────────────────────────

  # ── Agent event dispatch ──────────────────────────────────────────────────

  @spec route_agent_event(EditorState.t(), pid(), term()) :: {:noreply, EditorState.t()}
  defp route_agent_event(state, session_pid, event) do
    route_agent_event(state, session_pid, event, agent_event_owner(state, session_pid))
  end

  @spec route_agent_event(EditorState.t(), pid(), term(), atom()) :: {:noreply, EditorState.t()}
  defp route_agent_event(state, session_pid, event, :inline_edit) do
    state = InlineEditEvents.handle_event(state, session_pid, event)
    {:noreply, schedule_render(state, 16)}
  end

  defp route_agent_event(state, session_pid, event, :inline_ask) do
    state = InlineAskEvents.handle_event(state, session_pid, event)
    {:noreply, schedule_render(state, 16)}
  end

  defp route_agent_event(state, _session_pid, event, :active_agent) do
    state = dispatch_agent_event(state, event)
    {:noreply, state}
  end

  defp route_agent_event(state, session_pid, event, :background) do
    {shell_state, workspace, shell_effects} =
      state.shell.on_agent_event(state.shell_state, state.workspace, session_pid, event)

    state = %{state | shell_state: shell_state, workspace: workspace}
    state = apply_effects(state, shell_effects)
    {:noreply, schedule_render(state, 16)}
  end

  @spec agent_event_owner(EditorState.t(), pid()) ::
          :inline_edit | :inline_ask | :active_agent | :background
  defp agent_event_owner(state, session_pid) do
    if InlineEditEvents.session?(state, session_pid) do
      :inline_edit
    else
      agent_event_owner_without_inline_edit(state, session_pid)
    end
  end

  @spec agent_event_owner_without_inline_edit(EditorState.t(), pid()) ::
          :inline_ask | :active_agent | :background
  defp agent_event_owner_without_inline_edit(state, session_pid) do
    if InlineAskEvents.session?(state, session_pid) do
      :inline_ask
    else
      active_or_background_agent_event(state, session_pid)
    end
  end

  @spec active_or_background_agent_event(EditorState.t(), pid()) :: :active_agent | :background
  defp active_or_background_agent_event(state, session_pid) do
    if AgentAccess.session(state) == session_pid, do: :active_agent, else: :background
  end

  @spec dispatch_agent_event(EditorState.t(), term()) :: EditorState.t()
  defp dispatch_agent_event(state, event) do
    {state, effects} = Events.handle(state, event)
    apply_effects(state, effects)
  end

  # ── Agent lifecycle ──────────────────────────────────────────────────────

  @typedoc """
  Side effects returned by event handlers and pure state functions.

  * `:render` — schedule a debounced render
  * `{:render, delay_ms}` — schedule render with custom delay
  * `{:open_file, path}` — open a file in a new or existing buffer
  * `{:switch_buffer, pid}` — make this buffer active
  * `{:set_status, msg}` — show a status message in the minibuffer
  * `:clear_status` — clear the status message
  * `{:push_overlay, module}` — push an overlay handler onto the focus stack
  * `{:pop_overlay, module}` — pop an overlay handler from the focus stack
  * `{:log_message, msg}` — log to *Messages* buffer
  * `{:log_warning, msg}` — log to both *Messages* and *Warnings* (warning level)
  * `{:log, subsystem, level, msg}` — log via Minga.Log
  * `:sync_agent_buffer` — sync agent buffer with session output
  * `{:update_tab_label, label}` — update active tab label
  * `{:monitor, pid}` — monitor a buffer process
  * `{:stop_spinner}` — cancel outgoing agent spinner timer
  * `{:start_spinner}` — start incoming agent spinner timer
  * `{:rebuild_agent_session, tab}` — rebuild agent state from session process
  * `{:request_semantic_tokens}` — request semantic tokens from LSP
  * `{:send_after, msg, delay}` — schedule a self-send after delay
  * `{:conceal_spans, pid, spans}` — apply conceal spans to a buffer
  * `{:prettify_symbols, pid}` — run prettify symbols on a buffer
  * `{:update_agent_styled_cache}` — re-cache GUI styled messages
  * `{:evict_parser_trees_timer}` — schedule next eviction check
  * `{:refresh_tool_picker}` — refresh tool picker if open
  * `{:save_session_async, snapshot, opts}` — persist session in background
  * `{:restart_session_timer}` — restart the periodic session timer
  * `{:cancel_session_timer}` — cancel the periodic session timer
  * `{:recover_swap_entries, entries}` — recover swap file entries
  * `{:restore_session, opts}` — restore session from disk
  * `{:request_code_lens}` — request fresh code lenses from LSP
  * `{:request_inlay_hints}` — request fresh inlay hints from LSP
  * `:render_now` — render immediately after a handler updates state
  * `{:save_session_deferred}` — send :save_session to self
  * `{:schedule_file_tree_refresh, delay}` — debounce one filesystem tree refresh
  * `{:handle_git_remote_result, ref, result}` — process git remote result
  """
  @type effect ::
          :render
          | :render_now
          | {:render, delay_ms :: pos_integer()}
          | {:open_file, String.t()}
          | {:switch_buffer, pid()}
          | {:set_status, String.t()}
          | :clear_status
          | {:push_overlay, module()}
          | {:pop_overlay, module()}
          | {:log_message, String.t()}
          | {:log_warning, String.t()}
          | {:log, atom(), atom(), String.t()}
          | :sync_agent_buffer
          | {:update_tab_label, String.t()}
          | {:monitor, pid()}
          | :stop_spinner
          | :start_spinner
          | {:rebuild_agent_session, MingaEditor.State.Tab.t()}
          | {:request_semantic_tokens}
          | {:send_after, term(), non_neg_integer()}
          | {:conceal_spans, pid(), [map()]}
          | {:prettify_symbols, pid()}
          | {:update_agent_styled_cache}
          | {:evict_parser_trees_timer}
          | {:refresh_tool_picker}
          | {:save_session_async, term(), keyword()}
          | {:restart_session_timer}
          | {:cancel_session_timer}
          | {:recover_swap_entries, [Session.swap_entry()]}
          | {:restore_session, keyword()}
          | {:request_code_lens}
          | {:request_inlay_hints}
          | {:save_session_deferred}
          | {:schedule_file_tree_refresh, non_neg_integer()}
          | {:handle_git_remote_result, reference(), term()}

  @doc """
  Applies a list of effects to the editor state.

  Agent event handlers return `{new_state, [effect()]}` from their callbacks.
  The Editor interprets each effect. This keeps handlers testable as
  pure `state -> {state, effects}` functions.
  """
  @spec apply_effects(EditorState.t(), [effect()]) :: EditorState.t()
  def apply_effects(state, []), do: state

  def apply_effects(state, [effect | rest]) do
    state = apply_effect(state, effect)
    apply_effects(state, rest)
  end

  @spec apply_effect(EditorState.t(), effect()) :: EditorState.t()
  defp apply_effect(state, :render), do: schedule_render(state, 16)

  defp apply_effect(state, :render_now), do: Renderer.render_or_async(state)

  defp apply_effect(state, {:set_status, msg}) when is_binary(msg),
    do: EditorState.set_status(state, msg)

  defp apply_effect(state, {:open_file, path}) when is_binary(path),
    do: Commands.execute(state, {:edit_file, path})

  defp apply_effect(state, {:switch_buffer, pid}) when is_pid(pid) do
    case Enum.find_index(state.workspace.buffers.list, &(&1 == pid)) do
      nil -> state
      idx -> EditorState.switch_buffer(state, idx) |> reset_nav_flash_tracking()
    end
  end

  defp apply_effect(state, {:push_overlay, mod}) when is_atom(mod),
    do: %{state | focus_stack: [mod | state.focus_stack]}

  defp apply_effect(state, {:pop_overlay, mod}) when is_atom(mod),
    do: %{state | focus_stack: List.delete(state.focus_stack, mod)}

  defp apply_effect(state, {:render, delay_ms}) when is_integer(delay_ms),
    do: schedule_render(state, delay_ms)

  defp apply_effect(state, {:log_message, msg}) when is_binary(msg), do: log_message(state, msg)

  defp apply_effect(state, {:log_warning, msg}) when is_binary(msg) do
    Minga.Log.warning(:editor, msg)
    state = MessageLog.log(state, msg, :warning)
    maybe_schedule_warning_popup(state)
  end

  defp apply_effect(state, :sync_agent_buffer), do: AgentLifecycle.sync_buffer(state)

  defp apply_effect(state, {:update_tab_label, _label}),
    do: AgentLifecycle.maybe_update_tab_label(state)

  defp apply_effect(state, {:monitor, pid}) when is_pid(pid),
    do: EditorState.monitor_buffer(state, pid)

  defp apply_effect(state, :stop_spinner),
    do: AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)

  defp apply_effect(state, :start_spinner) do
    agent = AgentAccess.agent(state)

    if AgentState.busy?(agent) and agent.spinner_timer == nil do
      AgentAccess.update_agent(state, &AgentState.start_spinner_timer/1)
    else
      state
    end
  end

  defp apply_effect(state, {:rebuild_agent_session, %MingaEditor.State.Tab{kind: :agent} = tab}) do
    state
    |> EditorState.rebuild_agent_from_session(tab)
    |> AgentLifecycle.sync_buffer()
  end

  defp apply_effect(state, {:rebuild_agent_session, tab}),
    do: EditorState.rebuild_agent_from_session(state, tab)

  defp apply_effect(state, :clear_status), do: EditorState.clear_status(state)

  defp apply_effect(state, {:log, subsystem, level, msg})
       when is_atom(subsystem) and is_atom(level) and is_binary(msg) do
    apply_log_effect(subsystem, level, msg)
    state
  end

  defp apply_effect(state, {:request_semantic_tokens}),
    do: SemanticTokenSync.request_tokens(state)

  defp apply_effect(state, {:send_after, msg, delay}) when is_integer(delay) do
    if state.backend != :headless do
      Process.send_after(self(), msg, delay)
    end

    state
  end

  defp apply_effect(state, {:schedule_file_tree_refresh, delay}) when is_integer(delay) do
    if MingaEditor.FileTree.Freshness.refresh_scheduled?(state) do
      state
    else
      ref = Process.send_after(self(), :file_tree_refresh_timer, delay)
      MingaEditor.FileTree.Freshness.schedule_refresh(state, ref)
    end
  end

  defp apply_effect(state, {:conceal_spans, pid, spans}) when is_pid(pid) do
    MingaEditor.HighlightEvents.handle_conceal_spans(state, pid, spans)
    state
  end

  defp apply_effect(state, {:prettify_symbols, pid}) when is_pid(pid) do
    maybe_spawn_prettify(state)
    state
  end

  defp apply_effect(state, {:update_agent_styled_cache}),
    do: AgentLifecycle.update_styled_cache(state)

  defp apply_effect(state, {:evict_parser_trees_timer}) do
    if state.backend != :headless do
      Process.send_after(
        self(),
        :evict_parser_trees,
        HighlightSync.eviction_check_interval_ms()
      )
    end

    state
  end

  defp apply_effect(state, {:refresh_tool_picker}),
    do: maybe_refresh_tool_picker(state)

  defp apply_effect(state, {:save_session_async, snapshot, opts}) do
    Task.start(fn ->
      case Session.save(snapshot, opts) do
        :ok -> :ok
        {:error, reason} -> Minga.Log.warning(:editor, "Session save failed: #{inspect(reason)}")
      end
    end)

    state
  end

  defp apply_effect(state, {:restart_session_timer}),
    do: %{state | session: EditorSessionState.restart_timer(state.session)}

  defp apply_effect(state, {:cancel_session_timer}),
    do: %{state | session: EditorSessionState.cancel_timer(state.session)}

  defp apply_effect(state, {:recover_swap_entries, entries}),
    do: recover_swap_entries(state, entries)

  defp apply_effect(state, {:restore_session, _opts}),
    do: restore_session(state)

  defp apply_effect(state, {:request_code_lens}),
    do: LspActions.code_lens(state)

  defp apply_effect(state, {:request_inlay_hints}),
    do: LspActions.inlay_hints(state)

  defp apply_effect(state, {:save_session_deferred}) do
    if state.backend != :headless, do: send(self(), :save_session)
    state
  end

  defp apply_effect(state, {:handle_git_remote_result, ref, result}),
    do: Renderer.render_or_async(Commands.Git.handle_remote_result(state, ref, result))

  # Dispatches a log effect to the appropriate Minga.Log function.
  @spec apply_log_effect(atom(), atom(), String.t()) :: :ok
  defp apply_log_effect(subsystem, :debug, msg), do: Minga.Log.debug(subsystem, msg)
  defp apply_log_effect(subsystem, :info, msg), do: Minga.Log.info(subsystem, msg)
  defp apply_log_effect(subsystem, :warning, msg), do: Minga.Log.warning(subsystem, msg)
  defp apply_log_effect(subsystem, :error, msg), do: Minga.Log.error(subsystem, msg)

  # Spawns a prettify-symbols Task if enabled and the active buffer has highlights.
  @spec maybe_spawn_prettify(state()) :: :ok
  defp maybe_spawn_prettify(%{workspace: %{buffers: %{active: nil}}}), do: :ok

  defp maybe_spawn_prettify(state) do
    if MingaEditor.UI.PrettifySymbols.enabled?() do
      spawn_prettify_task(state)
    end

    :ok
  end

  @spec spawn_prettify_task(state()) :: :ok
  defp spawn_prettify_task(state) do
    hl = HighlightSync.get_active_highlight(state)

    if hl.capture_names != {} and tuple_size(hl.spans) > 0 do
      buf = state.workspace.buffers.active
      file_path = Minga.Buffer.file_path(buf)
      filetype = Minga.Language.detect_filetype(file_path)
      Task.start(fn -> MingaEditor.UI.PrettifySymbols.apply(buf, hl, filetype) end)
    end

    :ok
  end

  # Tab bar, view state, capabilities, parser subscription helpers

  # Agent lifecycle helpers (session startup, auto-context, buffer sync,

  # ── Render scheduling ────────────────────────────────────────────────────────

  # Schedules a render within `delay_ms` using throttle semantics.
  #
  # The first call renders immediately (delay_ms == 0 path) or schedules
  # at the given delay. Subsequent calls during an active window are
  # coalesced: the pending timer already covers them. The `:debounced_render`
  # handler clears `render_timer` so the next event after the window can
  # schedule again.
  #
  # For streaming agent responses, this ensures new text is visible within
  # one frame (~16ms) of arriving at the BEAM, because:
  # 1. First delta triggers an immediate or near-immediate render.
  # 2. Deltas arriving mid-window are picked up by the pending timer.
  # 3. The timer fires, renders the latest state, and clears the guard
  #    so the next delta can schedule again.
  # apply_textobject_positions moved to HighlightHandler

  @doc false
  @spec schedule_render(state(), non_neg_integer()) :: state()
  def schedule_render(%{render_timer: ref} = state, _delay_ms) when is_reference(ref), do: state

  # In test mode (headless backend), render synchronously to eliminate timer
  # races that cause CI flakiness. No debounce needed when there's no real
  # display to coalesce frames for.
  def schedule_render(%{backend: :headless} = state, _delay_ms) do
    state = maybe_trigger_nav_flash(state)
    state = Renderer.render_or_async(state)
    %{state | render_timer: nil}
  end

  def schedule_render(state, delay_ms) do
    effective_delay_ms = max(delay_ms, ResourcePressure.render_delay_ms(state.resource_pressure))
    ref = Process.send_after(self(), :debounced_render, effective_delay_ms)
    %{state | render_timer: ref}
  end

  # LSP status aggregation moved to MingaEditor.State.LSP

  # ── Diagnostic decorations ──────────────────────────────────────────────────

  # Applies diagnostic underline decorations to the buffer matching the URI.
  # Called when {:minga_event, :diagnostics_updated, ...} arrives via the event bus.
  @doc false
  @spec apply_diagnostic_decorations(state(), String.t()) :: :ok
  def apply_diagnostic_decorations(state, uri) do
    path = LspSyncServer.uri_to_path(uri)

    buf_pid =
      Enum.find(state.workspace.buffers.list, fn buf ->
        try do
          Buffer.file_path(buf) == path
        catch
          :exit, _ -> false
        end
      end)

    if buf_pid do
      DiagDecorations.apply(buf_pid, uri, state.theme.gutter)
    end

    :ok
  end

  # ── Nav-flash detection ───────────────────────────────────────────────────────

  # Checks if the cursor jumped far enough to trigger a nav-flash.
  # Updates `last_cursor_line` and, when the threshold is exceeded,
  # starts (or restarts) the flash animation.
  @spec maybe_trigger_nav_flash(state()) :: state()
  defp maybe_trigger_nav_flash(%{workspace: %{buffers: %{active: nil}}} = state), do: state

  defp maybe_trigger_nav_flash(state) do
    buf = state.workspace.buffers.active
    {current_line, _col} = Buffer.cursor(buf)

    state = detect_jump(state, current_line)
    %{state | last_cursor_line: current_line}
  end

  @spec detect_jump(state(), non_neg_integer()) :: state()
  defp detect_jump(%{last_cursor_line: nil} = state, _current_line), do: state

  defp detect_jump(state, current_line) do
    delta = abs(current_line - state.last_cursor_line)
    threshold = Config.get(:nav_flash_threshold)

    if delta >= threshold and Config.get(:nav_flash) do
      start_flash(state, current_line)
    else
      cancel_flash_if_active(state)
    end
  end

  @spec start_flash(state(), non_neg_integer()) :: state()
  defp start_flash(state, line) do
    flash = EditorState.nav_flash(state)
    old_timer = if flash, do: flash.timer, else: nil
    {new_flash, effects} = NavFlash.start(line, old_timer)
    EditorState.set_nav_flash(state, apply_flash_effects(state, new_flash, effects))
  end

  @spec cancel_flash_if_active(state()) :: state()
  defp cancel_flash_if_active(%{shell_state: %{nav_flash: nil}} = state), do: state

  defp cancel_flash_if_active(state) do
    effects = NavFlash.cancel_effects(EditorState.nav_flash(state))
    execute_flash_effects(state, effects)
    EditorState.cancel_nav_flash(state)
  end

  # Resets nav-flash tracking after a buffer switch so the cursor
  # position of the new buffer doesn't trigger a false-positive flash
  # from the old buffer's cursor line.
  @spec reset_nav_flash_tracking(state()) :: state()
  defp reset_nav_flash_tracking(state) do
    state = cancel_flash_if_active(state)
    %{state | last_cursor_line: nil}
  end

  # Cancels any active nav-flash. Called on every keypress.
  @spec cancel_nav_flash(state()) :: state()
  defp cancel_nav_flash(%{shell_state: %{nav_flash: nil}} = state), do: state

  defp cancel_nav_flash(state) do
    effects = NavFlash.cancel_effects(EditorState.nav_flash(state))
    execute_flash_effects(state, effects)
    EditorState.cancel_nav_flash(state)
  end

  @spec cancel_yank_flash(state()) :: state()
  defp cancel_yank_flash(%{shell_state: %{yank_flash: nil}} = state), do: state

  defp cancel_yank_flash(%{shell_state: %{yank_flash: flash}} = state) do
    effects = YankFlash.cancel_effects(flash)
    execute_flash_effects(state, effects)
    clear_yank_highlight(flash.buf)
    EditorState.cancel_yank_flash(state)
  end

  @spec update_yank_flash_decoration(pid(), YankFlash.t(), state()) :: :ok
  defp update_yank_flash_decoration(buf, flash, state) do
    flash_bg = state.theme.editor.yank_flash_bg || YankFlash.default_flash_bg()
    target_bg = state.theme.editor.bg
    color = YankFlash.color_for_step(flash, flash_bg, target_bg)

    {hl_start, hl_end} =
      YankFlash.highlight_bounds(buf, flash.start_pos, flash.end_pos, flash.range_type)

    try do
      Buffer.remove_highlight_group(buf, YankFlash.flash_group())

      Buffer.add_highlight(buf, hl_start, hl_end,
        style: Minga.Core.Face.new(bg: color),
        group: YankFlash.flash_group(),
        priority: 50
      )
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @spec clear_yank_highlight(pid()) :: :ok
  defp clear_yank_highlight(buf) do
    try do
      Buffer.remove_highlight_group(buf, YankFlash.flash_group())
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp apply_flash_effects(state, flash, effects) do
    MingaEditor.FlashEffects.apply(state, flash, effects)
  end

  defp execute_flash_effects(state, effects) do
    MingaEditor.FlashEffects.execute(state, effects)
  end

  # ── Key dispatch ─────────────────────────────────────────────────────────────

  @doc false
  @spec do_handle_key(state(), non_neg_integer(), non_neg_integer()) :: state()
  defdelegate do_handle_key(state, codepoint, modifiers), to: KeyDispatch, as: :handle_key

  @doc false
  @spec do_maybe_reset_highlight(state(), pid() | nil) :: state()
  defdelegate do_maybe_reset_highlight(state, old_buffer),
    to: HighlightEvents,
    as: :maybe_reset_highlight

  @doc false
  @spec do_maybe_reparse(state(), non_neg_integer()) :: state()
  defdelegate do_maybe_reparse(state, version_before),
    to: HighlightEvents,
    as: :maybe_reparse

  @doc false
  @spec dispatch_command(state(), Mode.command()) :: state()
  defdelegate dispatch_command(state, cmd), to: KeyDispatch

  # ── Paste event routing ───────────────────────────────────────────────────

  @spec handle_paste_event(state(), String.t()) :: state()
  defp handle_paste_event(state, text) do
    if AgentAccess.input_focused?(state) do
      # Agent input is focused (split panel or full-screen agentic view)
      Commands.Agent.input_paste(state, text)
    else
      handle_paste_event_editor(state, text)
    end
  end

  @spec handle_paste_event_editor(state(), String.t()) :: state()
  defp handle_paste_event_editor(%{workspace: %{buffers: %{active: buf}}} = state, text)
       when is_pid(buf) do
    {line, col} = Buffer.cursor(buf)
    Buffer.apply_edit(buf, line, col, line, col, text)
    state
  end

  defp handle_paste_event_editor(state, _text) do
    log_message(state, "Paste ignored (no active buffer)")
  end

  # ── File tree helpers ───────────────────────────────────────────────────

  @doc false
  @spec do_file_tree_open(state(), pid(), String.t(), FileTree.t()) :: state()
  def do_file_tree_open(state, pid, path, tree) do
    new_state = register_buffer(state, pid, path)

    EditorState.update_file_tree(new_state, fn file_tree ->
      FileTreeState.set_tree(file_tree, FileTree.reveal(tree, path))
    end)
  end

  @spec recover_swap_entries(state(), [Minga.Session.swap_entry()]) :: state()
  defp recover_swap_entries(state, entries) do
    count = length(entries)

    state =
      log_message(state, "Found #{count} file(s) with unsaved changes from a previous session")

    Enum.reduce(entries, state, &recover_swap_entry/2)
  end

  @spec recover_swap_entry(Minga.Session.swap_entry(), state()) :: state()
  defp recover_swap_entry(entry, state) do
    case Minga.Session.recover_swap_file(entry.swap_path) do
      {:ok, file_path, content} ->
        state = log_message(state, "Recovered: #{Path.basename(file_path)}")
        recover_buffer(state, file_path, content)

      {:error, reason} ->
        log_message(state, "Failed to recover #{Path.basename(entry.path)}: #{inspect(reason)}")
    end
  end

  @spec maybe_check_swap_recovery(state()) :: :ok
  defp maybe_check_swap_recovery(state) do
    if EditorSessionState.swap_enabled?(state.session) and state.backend != :headless do
      send(self(), :check_swap_recovery)
    end

    :ok
  end

  # Restores open files and cursor positions from the previous session.
  @spec restore_session(state()) :: state()
  defp restore_session(state) do
    case Session.load(EditorSessionState.session_opts(state.session)) do
      {:ok, session} ->
        state = log_message(state, "Restored from previous session")
        Enum.reduce(session.buffers, state, &restore_session_buffer/2)

      {:error, _} ->
        state
    end
  end

  @spec restore_session_buffer(Session.buffer_entry(), state()) :: state()
  defp restore_session_buffer(%{file: file} = entry, state) do
    if File.exists?(file) do
      case Commands.start_buffer(file, EditorState.options_server(state)) do
        {:ok, pid} ->
          :ok = Buffer.move_to(pid, {entry.cursor_line, entry.cursor_col})
          register_buffer(state, pid, file)

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  # Opens a file and replaces its content with recovered swap data.
  # The buffer is marked dirty since the recovered content hasn't been saved.
  @spec recover_buffer(state(), String.t(), String.t()) :: state()
  defp recover_buffer(state, file_path, content) do
    case Commands.start_buffer(file_path, EditorState.options_server(state)) do
      {:ok, pid} ->
        # Replace buffer content with the recovered swap data.
        # This marks the buffer dirty (unsaved changes from the crash).
        case Buffer.replace_content(pid, content, :recovery) do
          :ok ->
            register_buffer(state, pid, file_path)

          {:error, :read_only} ->
            log_message(state, "Cannot recover #{Path.basename(file_path)}: read-only")
        end

      {:error, reason} ->
        log_message(
          state,
          "Could not open buffer for #{Path.basename(file_path)}: #{inspect(reason)}"
        )
    end
  end

  # Shared buffer registration: adds buffer to the list, logs, refreshes
  # LSP status, and broadcasts :buffer_opened so event bus subscribers
  # (Git.Tracker, FileWatcher, Project, SyncServer, Config.Hooks) react.
  @spec register_buffer(state(), pid(), String.t()) :: state()
  defp register_buffer(state, buffer_pid, file_path) do
    state = Commands.add_buffer(state, buffer_pid)
    state = log_message(state, "Opened: #{file_path}")

    Minga.Events.broadcast(
      :buffer_opened,
      %Minga.Events.BufferEvent{
        buffer: buffer_pid,
        path: file_path
      },
      EditorState.events_registry(state)
    )

    # Eagerly set up syntax highlighting for this specific buffer.
    # Uses the PID-targeted variant so each restored buffer gets its
    # own parse request, not just whoever is active last.
    state = HighlightSync.setup_for_buffer_pid(state, buffer_pid)

    # Schedule code lens and inlay hint requests after LSP clients connect.
    # The SyncServer handles didOpen via the event bus; by the time 800ms
    # elapses the LSP client should be ready to serve requests.
    if state.backend != :headless do
      Process.send_after(self(), :request_code_lens_and_inlay_hints, 800)
    end

    state
  end

  @spec buffer_tracked?(state(), pid()) :: boolean()
  defp buffer_tracked?(state, pid) when is_pid(pid) do
    pid in state.workspace.buffers.list or buffer_tracked_in_tabs?(state, pid)
  end

  @spec buffer_tracked_in_tabs?(state(), pid()) :: boolean()
  defp buffer_tracked_in_tabs?(%{shell_state: %{tab_bar: %{tabs: tabs}}}, pid) do
    Enum.any?(tabs, fn tab -> pid in tab_buffer_list(tab) end)
  end

  defp buffer_tracked_in_tabs?(_state, _pid), do: false

  @spec tab_buffer_list(MingaEditor.State.Tab.t() | term()) :: [pid()]
  defp tab_buffer_list(%MingaEditor.State.Tab{context: context}) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{list: buffers}} -> Enum.filter(buffers, &is_pid/1)
      _ -> []
    end
  end

  defp tab_buffer_list(_tab), do: []

  # Like register_buffer but adds the buffer in the background without
  # switching the active window. Used by ensure_buffer_for_path so agent
  # edits don't yank the user away from their current file.
  # Skips code_lens/inlay_hint scheduling; those are lazy-loaded when
  # the user explicitly opens the buffer.
  @spec register_buffer_background(state(), pid(), String.t()) :: state()
  defp register_buffer_background(state, buffer_pid, file_path) do
    state =
      EditorState.update_buffers(state, &Buffers.add_background(&1, buffer_pid))

    state = EditorState.monitor_buffer(state, buffer_pid)
    log_message(state, "Opened (agent): #{file_path}")
  end

  @doc false
  @spec log_message(state(), String.t()) :: state()
  def log_message(state, text), do: MessageLog.log(state, text)

  @spec put_notification(state(), Notification.t()) :: state()
  defp put_notification(state, %Notification{} = notification) do
    notification = maybe_schedule_notification_dismiss(notification, state.backend)

    state
    |> log_notification(notification)
    |> EditorState.upsert_notification(notification)
  end

  @spec maybe_schedule_notification_dismiss(Notification.t(), EditorState.backend()) ::
          Notification.t()
  defp maybe_schedule_notification_dismiss(
         %Notification{auto_dismiss_ms: ms, id: id} = notification,
         backend
       )
       when is_integer(ms) and ms > 0 and backend != :headless do
    dismiss_ref = make_ref()
    Process.send_after(self(), {:dismiss_notification, id, dismiss_ref}, ms)
    Notification.with_dismiss_ref(notification, dismiss_ref)
  end

  defp maybe_schedule_notification_dismiss(%Notification{} = notification, _backend),
    do: notification

  @spec log_notification(state(), Notification.t()) :: state()
  defp log_notification(state, %Notification{} = notification) do
    source = if notification.source, do: "[#{notification.source}] ", else: ""
    body = if notification.body in [nil, ""], do: "", else: ": #{notification.body}"
    log_message(state, "#{source}#{notification.title}#{body}")
  end

  @doc false
  @spec update_test_notification(state(), non_neg_integer()) :: state()
  def update_test_notification(state, 0) do
    put_notification(
      state,
      Notification.new(
        id: "build:test",
        level: :success,
        title: "Build finished",
        body: "Tests passed",
        source: "Build",
        auto_dismiss_ms: 4_000
      )
    )
  end

  def update_test_notification(state, exit_code) do
    put_notification(
      state,
      Notification.new(
        id: "build:test",
        level: :error,
        title: "Build failed",
        body: "Test command exited with code #{exit_code}",
        source: "Build",
        actions: [
          %{id: "show_logs", label: "Show logs", dispatch: {:command, :test_output}},
          %{id: "retry", label: "Retry", dispatch: {:command, :test_rerun}}
        ]
      )
    )
  end

  @doc false
  @spec open_file_by_path(state(), String.t()) :: state()
  def open_file_by_path(state, abs_path) do
    case open_file_by_path_result(state, abs_path) do
      {:ok, new_state} -> new_state
      {:error, _reason} -> EditorState.set_status(state, "Could not open #{abs_path}")
    end
  end

  @doc false
  @spec open_file_by_path_result(state(), String.t()) :: {:ok, state()} | {:error, term()}
  def open_file_by_path_result(state, abs_path) do
    case file_tab_for_path_in_active_workspace(state, abs_path) do
      %Tab{id: id} -> {:ok, EditorState.switch_tab(state, id)}
      nil -> start_and_register_file(state, abs_path)
    end
  end

  @doc false
  @spec start_and_register_file(state(), String.t()) :: {:ok, state()} | {:error, term()}
  def start_and_register_file(state, abs_path) do
    case Commands.start_buffer(abs_path, EditorState.options_server(state)) do
      {:ok, pid} ->
        new_state = register_buffer(state, pid, abs_path)
        {:ok, AgentLifecycle.maybe_set_auto_context(new_state, abs_path, pid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec file_tab_for_path_in_active_workspace(state(), String.t()) :: Tab.t() | nil
  def file_tab_for_path_in_active_workspace(
        %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
        path
      ) do
    file_ref = FileRef.new(path)

    if active_buffer_matches_file_ref?(state, file_ref) do
      EditorState.active_tab(state)
    else
      TabBar.find_file_tab_in_workspace(tb, TabBar.active_workspace_id(tb), file_ref)
    end
  end

  def file_tab_for_path_in_active_workspace(_state, _path), do: nil

  @spec active_buffer_matches_file_ref?(state(), FileRef.t()) :: boolean()
  defp active_buffer_matches_file_ref?(
         %{workspace: %{buffers: %{active: active}}},
         %FileRef{} = file_ref
       )
       when is_pid(active) do
    case buffer_file_ref(active) do
      %FileRef{} = active_ref -> FileRef.same?(active_ref, file_ref)
      nil -> false
    end
  end

  defp active_buffer_matches_file_ref?(_state, _file_ref), do: false

  @spec buffer_file_ref(pid()) :: FileRef.t() | nil
  defp buffer_file_ref(pid) when is_pid(pid) do
    case Buffer.file_path(pid) do
      path when is_binary(path) -> FileRef.new(path)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc false
  @spec resolve_git_root() :: String.t() | nil
  def resolve_git_root do
    root = Minga.Project.resolve_root()

    case Minga.Git.root_for(root) do
      {:ok, git_root} -> git_root
      :not_git -> nil
    end
  end

  @doc false
  @spec refresh_git_repo(String.t()) :: :ok
  def refresh_git_repo(git_root) do
    case Git.lookup_repo(git_root) do
      nil -> :ok
      pid -> Git.Repo.refresh(pid)
    end
  end

  # Refreshes the tool manager picker items if it's currently open.
  # Called when tool install events change tool status so the user
  # sees live updates (spinner → checkmark, etc.).
  @spec maybe_refresh_tool_picker(state()) :: state()
  defp maybe_refresh_tool_picker(
         %{
           shell_state: %{
             modal: {:picker, %{picker_ui: %{source: MingaEditor.UI.Picker.Sources.Tool}}}
           }
         } = state
       ) do
    PickerUI.refresh_items(state)
  end

  defp maybe_refresh_tool_picker(state), do: state

  # maybe_show_tool_prompt moved to ToolHandler

  # ── Warning popup debounce ───────────────────────────────────────────────

  @warning_popup_debounce_ms 200

  @spec maybe_schedule_warning_popup(state()) :: state()
  defp maybe_schedule_warning_popup(%{shell_state: %{warning_popup_timer: ref}} = state)
       when is_reference(ref) do
    # Timer already running; the pending timeout will open the popup.
    state
  end

  defp maybe_schedule_warning_popup(%{backend: :headless} = state), do: state

  defp maybe_schedule_warning_popup(state) do
    ref = Process.send_after(self(), :warning_popup_timeout, @warning_popup_debounce_ms)
    EditorState.update_shell_state(state, &%{&1 | warning_popup_timer: ref})
  end

  @spec open_warnings_popup_if_needed(state()) :: state()
  defp open_warnings_popup_if_needed(%{shell_state: %{bottom_panel: %{dismissed: true}}} = state),
    do: state

  defp open_warnings_popup_if_needed(
         %{shell_state: %{bottom_panel: %{visible: true, active_tab: :messages}}} = state
       ) do
    # Panel already visible on Messages tab; don't change the user's filter.
    schedule_render(state, 16)
  end

  defp open_warnings_popup_if_needed(state) do
    # Auto-open the bottom panel with warnings filter preset
    new_panel = BottomPanel.show(EditorState.bottom_panel(state), :messages, :warnings)
    schedule_render(EditorState.set_bottom_panel(state, new_panel), 16)
  end

  # buffer_visible_in_window? moved to HighlightHandler

  # ── Window resize ────────────────────────────────────────────────────────

  @spec resize_all_windows(state()) :: state()
  defp resize_all_windows(%{workspace: %{windows: %{tree: nil}}} = state), do: state

  defp resize_all_windows(state) do
    layout = Layout.get(state)

    Enum.reduce(layout.window_layouts, state, fn {id, wl}, acc ->
      {_r, _c, width, height} = wl.total

      EditorState.update_window(acc, id, fn window ->
        Window.resize(window, height, width)
      end)
    end)
  end

  # ── File tree helpers ────────────────────────────────────────────────────

  # refresh_tree_git_status moved to FileEventHandler

  # ── Public housekeeping API for Input.Router ───────────────────────────────

  @doc false
  @spec do_accept_completion(state(), Completion.t()) :: state()
  defdelegate do_accept_completion(state, completion), to: CompletionHandling, as: :accept

  @doc false
  @spec do_maybe_handle_completion(state(), boolean(), non_neg_integer(), non_neg_integer()) ::
          state()
  defdelegate do_maybe_handle_completion(state, was_inserting, codepoint, modifiers),
    to: CompletionHandling,
    as: :maybe_handle

  @doc false
  @spec do_render(state()) :: state()
  def do_render(state) do
    Renderer.render_or_async(state)
  end

  @doc false
  @spec do_dismiss_completion(state()) :: state()
  defdelegate do_dismiss_completion(state), to: CompletionHandling, as: :dismiss
end
