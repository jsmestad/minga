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
  alias Minga.Git

  alias Minga.Diagnostics.Decorations, as: DiagDecorations
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands
  alias MingaEditor.CompletionHandling
  alias MingaEditor.FileWatcherHelpers
  alias MingaEditor.HighlightEvents
  alias MingaEditor.HighlightSync
  alias MingaEditor.KeyDispatch
  alias MingaEditor.Layout
  alias MingaEditor.InlineAsk.Events, as: InlineAskEvents
  alias MingaEditor.InlineEdit.Events, as: InlineEditEvents
  alias MingaEditor.MessageLog
  alias MingaEditor.NavFlash
  alias MingaEditor.Observatory
  alias MingaEditor.YankFlash
  alias MingaEditor.Renderer
  alias MingaEditor.SemanticTokenSync
  alias MingaEditor.Startup
  alias MingaEditor.State.ResourcePressure
  alias MingaEditor.Shell.StateStash
  alias MingaEditor.Viewport

  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Handlers.EffectHandler
  alias MingaEditor.Handlers.EventDispatcher
  alias MingaEditor.Handlers.FileEventHandler
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Handlers.HighlightHandler
  alias MingaEditor.Handlers.LspEventHandler
  alias MingaEditor.Handlers.RenderHandler
  alias MingaEditor.Handlers.SessionHandler
  alias MingaEditor.Handlers.SessionRestore
  alias MingaEditor.Handlers.ToolHandler
  # WarningLog removed in #825; warnings route through MessageLog with level override
  alias MingaEditor.Window
  alias MingaEditor.Input
  alias Minga.LSP.SyncServer, as: LspSyncServer
  alias Minga.Mode
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
          | {:view_mode, Minga.CLI.view_mode()}
          | {:shell, :traditional | :board | module()}
          | {:project_root, String.t() | nil}
          | {:swap_dir, String.t()}
          | {:session_dir, String.t()}
          | {:suppress_tool_prompts, boolean()}

  alias MingaEditor.State, as: EditorState

  alias MingaEditor.State.Session, as: EditorSessionState

  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload

  alias MingaEditor.MouseHoverTooltip

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
    case BufferRegistry.open_file_by_path_result(state, file_path) do
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
          if BufferRegistry.buffer_tracked?(state, pid) do
            state
          else
            BufferRegistry.register_buffer_background(state, pid, Path.expand(path))
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

  def handle_call({:cleanup_feature_state, source}, _from, state) do
    state = EditorState.drop_feature_state_source(state, source)
    {:reply, :ok, Renderer.render_or_async(state)}
  end

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:register_background_buffer, pid, abs_path}, state) do
    # Register a buffer that was started by Buffer.ensure_for_path (called
    # from agent tools or Editor.ensure_buffer_for_path). Only register if
    # the buffer isn't already tracked in the workspace.
    already_tracked? = BufferRegistry.buffer_tracked?(state, pid)

    if already_tracked? do
      {:noreply, state}
    else
      state = BufferRegistry.register_buffer_background(state, pid, abs_path)
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
       |> EditorState.set_viewport(vp)
       |> EditorState.reset_frontend_render_state())
      | capabilities: caps,
        layout: nil
    }

    Startup.send_font_config(new_state)
    push_full_config_state(new_state)
    new_state = Renderer.render_or_async(new_state)
    # Setup highlighting after first paint with correct viewport
    new_state = setup_highlight_or_defer(new_state)

    SessionRestore.maybe_check_swap_recovery(new_state)

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
    {:noreply, EffectHandler.apply_effects(new_state, effects)}
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

  def handle_info({:observatory_tick, token}, state) do
    if current_observatory_token?(state, token) do
      data = build_observatory_data()
      next_token = make_ref()
      timer = Process.send_after(self(), {:observatory_tick, next_token}, 1_000)

      new_state =
        state
        |> EditorState.set_observatory_data(data)
        |> EditorState.set_observatory_timer({timer, next_token})

      {:noreply, Renderer.render_or_async(new_state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:observatory_tick, state) do
    {:noreply, state}
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
    {:noreply, EffectHandler.apply_effects(state, effects)}
  end

  # ── Highlight events from Parser.Manager ──────────────────────────────────────
  # These arrive as {:minga_highlight, event} from the dedicated parser process.
  # Legacy {:minga_input, event} forms are also accepted for backward
  # compatibility during the transition (headless tests, etc.).
  # Log messages from the renderer port also arrive via {:minga_input, {:log_message, ...}}.
  # All {:minga_highlight, _} messages go straight to HighlightHandler.

  def handle_info({:minga_highlight, _} = msg, state) do
    {state, effects} = HighlightHandler.handle(state, msg)
    {:noreply, EffectHandler.apply_effects(state, effects)}
  end

  # Remaining {:minga_input, _} messages are highlight/parser events forwarded
  # via the legacy input tag. All input-specific :minga_input clauses (ready,
  # resize, key_press, paste_event, mouse_event, gui_action,
  # capabilities_updated) are matched above, so this catch-all is safe.
  def handle_info({:minga_input, _} = msg, state) do
    {state, effects} = HighlightHandler.handle(state, msg)
    {:noreply, EffectHandler.apply_effects(state, effects)}
  end

  # LSP/completion timer events routed through a focused handler.
  def handle_info({:completion_debounce, _clients, _buffer_pid} = msg, state) do
    {state, effects} = LspEventHandler.handle(state, msg)
    {:noreply, EffectHandler.apply_effects(state, effects)}
  end

  def handle_info({:lsp_response, _ref, _result} = msg, state) do
    {state, effects} = LspEventHandler.handle(state, msg)
    {:noreply, EffectHandler.apply_effects(state, effects)}
  end

  @lsp_debounce_atoms [:inlay_hint_scroll_debounce, :document_highlight_debounce]

  def handle_info(msg, state) when msg in @lsp_debounce_atoms do
    {state, effects} = LspEventHandler.handle(state, msg)
    {:noreply, EffectHandler.apply_effects(state, effects)}
  end

  def handle_info({:completion_resolve, _index} = msg, state) do
    {state, effects} = LspEventHandler.handle(state, msg)
    {:noreply, EffectHandler.apply_effects(state, effects)}
  end

  def handle_info(:request_code_lens_and_inlay_hints = msg, state) do
    {state, effects} = LspEventHandler.handle(state, msg)
    {:noreply, EffectHandler.apply_effects(state, effects)}
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
    {:noreply, RenderHandler.handle_debounced_render(state)}
  end

  # Debounced file-tree refresh timer fired — rescan the cached tree once for a burst of filesystem events.
  def handle_info(:file_tree_refresh_timer, state) do
    {state, effects} = FileEventHandler.handle(state, :file_tree_refresh_timer)
    {:noreply, EffectHandler.apply_effects(state, effects)}
  end

  # Renderer.Server writeback after each async frame completes.
  # EditorState narrows the merge to renderer-owned fields only.
  def handle_info({:render_done, %{caches: _caches, layout: _layout} = wb}, state) do
    {:noreply, RenderHandler.handle_render_done(state, wb)}
  end

  # Nav-flash timer step — advance the fade or clear the flash.
  def handle_info(:nav_flash_step, state) do
    {:noreply, RenderHandler.handle_nav_flash_step(state)}
  end

  # Yank-flash timer step — advance the fade or clear the flash.
  def handle_info(:yank_flash_step, state) do
    {:noreply, RenderHandler.handle_yank_flash_step(state)}
  end

  # Warning popup debounce timer fired — open the *Warnings* popup if not
  # already visible.
  def handle_info(:warning_popup_timeout, state) do
    {:noreply, RenderHandler.handle_warning_popup_timeout(state)}
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
      if ModalOverlay.active?(EditorState.modal(state)) do
        EditorState.set_status(state, "Commit message ready (prompt already open)")
      else
        state
        |> open_git_commit_prompt(default: message)
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
    {:noreply, EffectHandler.apply_effects(state, effects)}
  end

  # ── Async picker candidate fetching ─────────────────────────────────────
  # When a picker source is async, PickerUI.open/3 opens the picker immediately
  # with a loading indicator, then sends this message to spawn the background fetch.

  def handle_info({:picker_fetch_candidates, source_module, ctx}, state) do
    editor = self()

    Task.start(fn ->
      result =
        try do
          {:ok, source_module.candidates(ctx)}
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, "Source timed out: #{inspect(reason)}"}
          :throw, value -> {:error, "Source failed: #{inspect(value)}"}
        end

      send(editor, {:picker_candidates_result, source_module, result})
    end)

    {:noreply, state}
  end

  def handle_info({:picker_candidates_result, source_module, result}, state) do
    case state.shell_state.modal do
      {:picker, %{picker_ui: %{source: ^source_module}} = payload} ->
        new_state = handle_picker_candidates(state, payload, result)
        {:noreply, Renderer.render_or_async(new_state)}

      _ ->
        {:noreply, state}
    end
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

  @spec handle_picker_candidates(
          state(),
          PickerPayload.t(),
          {:ok, [term()]} | {:error, String.t()}
        ) :: state()
  defp handle_picker_candidates(state, payload, {:ok, items}) do
    picker_state = payload.picker_ui
    picker = MingaEditor.UI.Picker.replace_items(picker_state.picker, items)
    new_picker_state = %{picker_state | picker: picker, load_status: :ready}

    ModalOverlay.transition(
      state,
      :picker,
      PickerPayload.put_picker_ui(payload, new_picker_state)
    )
  end

  defp handle_picker_candidates(state, payload, {:error, reason}) do
    picker_state = payload.picker_ui
    new_picker_state = %{picker_state | load_status: {:error, reason}}

    ModalOverlay.transition(
      state,
      :picker,
      PickerPayload.put_picker_ui(payload, new_picker_state)
    )
  end

  @spec current_observatory_token?(state(), reference()) :: boolean()
  defp current_observatory_token?(
         %{shell_state: %{observatory_visible: true, observatory_timer: {_timer, token}}},
         token
       ),
       do: true

  defp current_observatory_token?(_state, _token), do: false

  @spec build_observatory_data() :: Observatory.Data.t()
  defp build_observatory_data do
    case Minga.SystemObserver.snapshot() do
      %{processes: processes} ->
        processes
        |> Minga.SystemObserver.TreeNode.build_tree()
        |> Observatory.Data.visible(Minga.SystemObserver.samples())

      nil ->
        Observatory.Data.visible(nil, [])
    end
  catch
    :exit, _ -> Observatory.Data.visible(nil, [])
  end

  # ── :DOWN classifier ────────────────────────────────────────────────────────

  @spec classify_down(EditorState.t(), reference(), pid(), term()) ::
          :buffer | {:git_remote_task, EditorState.t()} | :unknown
  defp classify_down(state, ref, pid, reason) do
    if Map.has_key?(state.buffer_monitors, pid) do
      :buffer
    else
      case handle_git_remote_task_down(state, ref, reason) do
        :not_matched -> :unknown
        updated_state -> {:git_remote_task, updated_state}
      end
    end
  end

  @spec open_git_commit_prompt(EditorState.t(), keyword()) :: EditorState.t()
  defp open_git_commit_prompt(state, opts) when is_list(opts) do
    prompt = :"Elixir.MingaGitPorcelain.UI.Prompt.GitCommit"

    if git_porcelain_running?() and Code.ensure_loaded?(prompt) do
      MingaEditor.PromptUI.open(state, prompt, opts)
    else
      state
    end
  end

  @spec handle_git_remote_task_down(EditorState.t(), reference(), term()) ::
          :not_matched | EditorState.t()
  defp handle_git_remote_task_down(state, ref, reason) do
    module = :"Elixir.MingaGitPorcelain.Commands"

    if git_porcelain_running?() and Code.ensure_loaded?(module) and
         function_exported?(module, :handle_remote_task_down, 3) do
      :erlang.apply(module, :handle_remote_task_down, [state, ref, reason])
    else
      :not_matched
    end
  end

  @spec git_porcelain_running?() :: boolean()
  defp git_porcelain_running? do
    case Process.whereis(Minga.Extension.Registry) do
      nil -> false
      _pid -> git_porcelain_running_in_registry?()
    end
  catch
    :exit, _reason -> false
  end

  @spec git_porcelain_running_in_registry?() :: boolean()
  defp git_porcelain_running_in_registry? do
    case Minga.Extension.Registry.get(:minga_git_porcelain) do
      {:ok, %{status: :running}} -> true
      _ -> false
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
    state = %{state | font_size_override: nil}
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
    state = EditorState.ensure_shell_available(state)
    state = route_active_shell_agent_event(state, session_pid, event)
    state = route_stashed_shell_agent_event(state, session_pid, event)
    {:noreply, schedule_render(state, 16)}
  end

  @spec route_active_shell_agent_event(EditorState.t(), pid(), term()) :: EditorState.t()
  defp route_active_shell_agent_event(state, session_pid, event) do
    {shell_state, workspace, shell_effects} =
      EditorState.active_shell_module(state).on_agent_event(
        state.shell_state,
        state.workspace,
        session_pid,
        event
      )

    state
    |> Map.replace!(:shell_state, shell_state)
    |> Map.replace!(:workspace, workspace)
    |> EffectHandler.apply_effects(shell_effects)
  end

  @spec route_stashed_shell_agent_event(EditorState.t(), pid(), term()) :: EditorState.t()
  defp route_stashed_shell_agent_event(state, session_pid, event) do
    {stash, state} =
      Enum.reduce(state.shell_state_stash, {state.shell_state_stash, state}, fn
        {shell_id, %StateStash{} = stashed}, {stash_acc, state_acc} ->
          route_stashed_shell_agent_event(
            stash_acc,
            state_acc,
            shell_id,
            stashed,
            session_pid,
            event
          )

        _entry, acc ->
          acc
      end)

    %{state | shell_state_stash: stash}
  end

  @spec route_stashed_shell_agent_event(
          EditorState.shell_state_stash(),
          EditorState.t(),
          EditorState.shell_id(),
          StateStash.t(),
          pid(),
          term()
        ) :: {EditorState.shell_state_stash(), EditorState.t()}
  defp route_stashed_shell_agent_event(
         stash,
         state,
         shell_id,
         %StateStash{} = stashed,
         session_pid,
         event
       ) do
    if function_exported?(stashed.module, :on_agent_event, 4) do
      apply_stashed_shell_agent_event(stash, state, shell_id, stashed, session_pid, event)
    else
      {stash, state}
    end
  end

  @spec apply_stashed_shell_agent_event(
          EditorState.shell_state_stash(),
          EditorState.t(),
          EditorState.shell_id(),
          StateStash.t(),
          pid(),
          term()
        ) :: {EditorState.shell_state_stash(), EditorState.t()}
  defp apply_stashed_shell_agent_event(
         stash,
         state,
         shell_id,
         %StateStash{} = stashed,
         session_pid,
         event
       ) do
    {shell_state, workspace, effects} =
      stashed.module.on_agent_event(stashed.state, state.workspace, session_pid, event)

    shell_state = maybe_persist_stashed_shell_state(stashed.module, stashed.state, shell_state)
    stash = Map.put(stash, shell_id, %StateStash{stashed | state: shell_state})
    state = EffectHandler.apply_effects(%{state | workspace: workspace}, effects)
    {stash, state}
  end

  @spec maybe_persist_stashed_shell_state(module(), term(), term()) :: term()
  defp maybe_persist_stashed_shell_state(module, old_state, new_state) do
    if old_state != new_state and function_exported?(module, :persist_shell_state, 1) do
      module.persist_shell_state(new_state)
    else
      new_state
    end
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
    EffectHandler.apply_effects(state, effects)
  end

  # ── Agent lifecycle ──────────────────────────────────────────────────────

  @type effect :: EffectHandler.effect()

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
  @spec schedule_render_delay_ms(state(), non_neg_integer()) :: non_neg_integer()
  def schedule_render_delay_ms(%EditorState{} = state, delay_ms)
      when is_integer(delay_ms) and delay_ms >= 0 do
    max(delay_ms, ResourcePressure.render_delay_ms(state.resource_pressure))
  end

  @doc false
  @spec schedule_render(state(), non_neg_integer()) :: state()
  def schedule_render(%{render_timer: ref} = state, _delay_ms) when is_reference(ref), do: state

  # In test mode (headless backend), render synchronously to eliminate timer
  # races that cause CI flakiness. No debounce needed when there's no real
  # display to coalesce frames for.
  def schedule_render(%{backend: :headless} = state, _delay_ms) do
    state = RenderHandler.maybe_trigger_nav_flash(state)
    state = Renderer.render_or_async(state)
    %{state | render_timer: nil}
  end

  def schedule_render(state, delay_ms) do
    effective_delay_ms = schedule_render_delay_ms(state, delay_ms)
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

  # ── Nav/yank flash cancellation ────────────────────────────────────────────

  # Resets nav-flash tracking after a buffer switch so the cursor
  # position of the new buffer doesn't trigger a false-positive flash
  # from the old buffer's cursor line.
  @doc false
  @spec reset_nav_flash_tracking(state()) :: state()
  def reset_nav_flash_tracking(state) do
    state = cancel_nav_flash(state)
    %{state | last_cursor_line: nil}
  end

  # Cancels any active nav-flash. Called on every keypress.
  @doc false
  @spec cancel_nav_flash(state()) :: state()
  def cancel_nav_flash(%{shell_state: %{nav_flash: nil}} = state), do: state

  def cancel_nav_flash(state) do
    effects = NavFlash.cancel_effects(EditorState.nav_flash(state))
    MingaEditor.FlashEffects.execute(state, effects)
    EditorState.cancel_nav_flash(state)
  end

  @doc false
  @spec cancel_yank_flash(state()) :: state()
  def cancel_yank_flash(%{shell_state: %{yank_flash: nil}} = state), do: state

  def cancel_yank_flash(%{shell_state: %{yank_flash: flash}} = state) do
    effects = YankFlash.cancel_effects(flash)
    MingaEditor.FlashEffects.execute(state, effects)

    try do
      Buffer.remove_highlight_group(flash.buf, YankFlash.flash_group())
    catch
      :exit, _ -> :ok
    end

    EditorState.cancel_yank_flash(state)
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

  # ── Tool picker refresh ─────────────────────────────────────────────

  # Refreshes the tool manager picker items if it's currently open.
  # Called when tool install events change tool status so the user
  # sees live updates (spinner -> checkmark, etc.).
  @doc false
  @spec maybe_refresh_tool_picker(state()) :: state()
  def maybe_refresh_tool_picker(
        %{
          shell_state: %{
            modal: {:picker, %{picker_ui: %{source: MingaEditor.UI.Picker.Sources.Tool}}}
          }
        } = state
      ) do
    MingaEditor.PickerUI.refresh_items(state)
  end

  def maybe_refresh_tool_picker(state), do: state

  @doc false
  @spec log_message(state(), String.t()) :: state()
  def log_message(state, text), do: MessageLog.log(state, text)

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

  # ── Warning popup debounce ───────────────────────────────────────────────

  @warning_popup_debounce_ms 200

  @doc false
  @spec maybe_schedule_warning_popup(state()) :: state()
  def maybe_schedule_warning_popup(%{shell_state: %{warning_popup_timer: ref}} = state)
      when is_reference(ref) do
    # Timer already running; the pending timeout will open the popup.
    state
  end

  def maybe_schedule_warning_popup(%{backend: :headless} = state), do: state

  def maybe_schedule_warning_popup(state) do
    ref = Process.send_after(self(), :warning_popup_timeout, @warning_popup_debounce_ms)
    EditorState.update_shell_state(state, &%{&1 | warning_popup_timer: ref})
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
