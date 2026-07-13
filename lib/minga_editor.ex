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
  alias Minga.Editing.Completion
  alias Minga.Events, as: EventBus
  alias Minga.Git

  alias Minga.Diagnostics.Decorations, as: DiagDecorations
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands
  alias MingaEditor.CompletionHandling
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileWatcherHelpers
  alias MingaEditor.HighlightEvents
  alias MingaEditor.HighlightSync
  alias MingaEditor.KeyDispatch
  alias MingaEditor.Layout
  alias MingaEditor.InlineAsk.Events, as: InlineAskEvents
  alias MingaEditor.InlineEdit.Events, as: InlineEditEvents

  alias MingaEditor.NavFlash
  alias MingaEditor.Observatory
  alias MingaEditor.YankFlash
  alias MingaEditor.Renderer
  alias MingaEditor.SemanticTokenSync
  alias MingaEditor.Startup
  alias MingaEditor.State.ResourcePressure
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
  alias MingaEditor.Handlers.ToolHandler
  # WarningLog removed in #825; warnings route through MessageLog with level override
  alias MingaEditor.Window
  alias MingaEditor.Input
  alias Minga.LSP.SyncServer, as: LspSyncServer
  alias Minga.Mode
  alias Minga.Log
  alias Minga.Telemetry.StartupTimer
  # PopupLifecycle alias removed: warnings popup replaced by bottom panel (#825)

  @typedoc "Options for starting the editor."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:backend, MingaEditor.State.backend()}
          | {:port_manager, GenServer.server()}
          | {:parser_manager, GenServer.server()}
          | {:keymap_server, GenServer.server()}
          | {:options_server, GenServer.server() | nil}
          | {:events_registry, EventBus.registry()}
          | {:effect_scheduler, GenServer.server()}
          | {:buffer, pid()}
          | {:width, pos_integer()}
          | {:height, pos_integer()}
          | {:editing_model, :vim | :cua}
          | {:view_mode, Minga.CLI.view_mode()}
          | {:shell, :traditional | module()}
          | {:project_root, String.t() | nil}
          | {:swap_dir, String.t()}
          | {:session_dir, String.t()}
          | {:suppress_tool_prompts, boolean()}

  alias MingaEditor.State, as: EditorState

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
    StartupTimer.mark(:editor_init)

    # Tune GC for the Editor process: frequent full sweeps reclaim binary
    # refs from the render loop, and a larger initial heap avoids repeated
    # grow-and-GC cycles during startup.
    Process.flag(:fullsweep_after, 20)
    Process.flag(:min_heap_size, 4096)

    state = Startup.build_initial_state(opts)
    :ok = attach_effect_scheduler(state.effect_scheduler)

    renderer_pid = renderer_pid_for_backend(state.backend)

    if state.backend != :headless and is_nil(renderer_pid) do
      Log.warning(:editor, "Renderer.Server not found at init; rendering synchronously")
    end

    state = EditorState.set_renderer(state, renderer_pid)

    # Agent stream coalescer (#2289). Linked to the Editor so it shares the
    # Editor's lifecycle: it subscribes to agent sessions on the Editor's behalf
    # and forwards coalesced {:agent_stream_batch, ...} messages back here,
    # keeping per-delta traffic out of the Editor mailbox.
    {:ok, ingest} = MingaEditor.Agent.Ingest.start_link(editor: self())
    state = EditorState.set_agent_ingest(state, ingest)

    # Logger redirect and startup messages
    if state.backend != :headless do
      log_path = Minga.LoggerHandler.install()
      Log.info(:editor, "Editor started")
      Log.info(:editor, "Log file: #{log_path}")
    else
      Log.info(:editor, "Editor started")
    end

    state = Startup.apply_config_options(state)
    events_registry = EditorState.events_registry(state)
    EventBus.subscribe(:diagnostics_updated, events_registry)
    EventBus.subscribe(:lsp_status_changed, events_registry)

    # Refresh file tree state when buffers, project files, git, diagnostics, or project roots change.
    EventBus.subscribe(:buffer_saved, events_registry)
    EventBus.subscribe(:buffer_changed, events_registry)
    EventBus.subscribe(:file_written, events_registry)
    EventBus.subscribe(:project_rebuilt, events_registry)
    EventBus.subscribe(:git_status_changed, events_registry)
    EventBus.subscribe(:command_done, events_registry)

    # Tool manager progress: show install/update status in the status line.
    EventBus.subscribe(:tool_install_started, events_registry)
    EventBus.subscribe(:tool_install_progress, events_registry)
    EventBus.subscribe(:tool_install_complete, events_registry)
    EventBus.subscribe(:tool_install_failed, events_registry)
    EventBus.subscribe(:tool_uninstall_complete, events_registry)
    EventBus.subscribe(:tool_missing, events_registry)
    EventBus.subscribe(:log_message, events_registry)
    EventBus.subscribe(:face_overrides_changed, events_registry)
    EventBus.subscribe(:agent_session_stopped, events_registry)
    EventBus.subscribe(:agent_session_restarted, events_registry)
    EventBus.subscribe(:background_subagent_started, events_registry)
    EventBus.subscribe(:node_connected, events_registry)
    EventBus.subscribe(:node_disconnected, events_registry)
    EventBus.subscribe(:load_user_themes, events_registry)
    EventBus.subscribe(:option_changed, events_registry)
    EventBus.subscribe(:extension_updates_available, events_registry)

    # Monitor all initial buffers so we get :DOWN when they die.
    all_initial_pids =
      state.workspace.buffers.list ++
        Enum.filter(
          [state.workspace.buffers.help],
          &is_pid/1
        )

    state = EditorState.monitor_buffers(state, all_initial_pids)

    # Schedule periodic eviction of inactive tree-sitter parse trees.
    if state.backend != :headless do
      Process.send_after(self(), :evict_parser_trees, HighlightSync.eviction_check_interval_ms())
    end

    # Legacy no-op retained for callers from the former transcript-buffer path.
    state = AgentLifecycle.setup_agent_highlight(state)

    StartupTimer.mark(:editor_init_done)
    StartupTimer.schedule_fallback_report()
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

  @spec attach_effect_scheduler(GenServer.server() | nil) :: :ok
  defp attach_effect_scheduler(nil), do: :ok

  defp attach_effect_scheduler(scheduler) do
    :ok = EffectScheduler.attach(scheduler, self())
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

    if result == :ok do
      Log.info(:editor, "Saved: #{Commands.Helpers.buffer_display_name(buf)}")
    end

    new_state = Renderer.render_or_async(state)
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

  def handle_cast(:render, state) do
    state = Renderer.render_or_async(state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:minga_input, {:ready, width, height}}, state) do
    StartupTimer.mark(:frontend_ready_received)

    # Query capabilities from the frontend (may have been sent in extended ready).
    caps = Startup.fetch_capabilities(state.port_manager)
    Startup.apply_gui_defaults(caps, EditorState.options_server(state))

    # The frontend already floored content pixels into rows-that-fit at the
    # current presentation metrics (ADR-0001); the BEAM lays out in the rows it
    # is given and derives nothing from line spacing.
    vp = Viewport.new(height, width)

    new_state = %{
      (state
       |> EditorState.set_terminal_viewport(vp)
       |> EditorState.set_viewport(vp)
       |> EditorState.reset_frontend_render_state())
      | capabilities: caps,
        layout: nil
    }

    Startup.send_font_config(new_state)
    new_state = refresh_gui_config_state(new_state)
    new_state = Renderer.reset_connection(new_state)
    StartupTimer.mark(:first_render_dispatched)
    StartupTimer.report()

    new_state = setup_highlight_or_defer(new_state)
    new_state = Startup.ensure_session_started(new_state)

    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:capabilities_updated, caps}}, state) do
    Log.info(
      :editor,
      "Frontend capabilities updated: #{inspect(caps.frontend_type)}, color: #{inspect(caps.color_depth)}"
    )

    {:noreply, %{state | capabilities: caps}}
  end

  def handle_info({:minga_input, {:resize, width, height}}, state) do
    # `height` is content rows-that-fit as measured by the frontend at the
    # current presentation metrics (ADR-0001). No spacing arithmetic here.
    vp = Viewport.new(height, width)

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
  def handle_info({:minga_input, {:key_press, codepoint, modifiers, seq}}, state) do
    state = cancel_nav_flash(state)
    state = cancel_yank_flash(state)
    # Record the input correlation sequence (ticket #2215) so the render that
    # this keystroke triggers echoes it on commit_frame for latency resolution.
    state = %{state | last_input_seq: seq}

    new_state =
      Minga.Telemetry.span([:minga, :input, :dispatch], %{input_seq: seq}, fn ->
        Input.Router.dispatch(state, codepoint, modifiers)
      end)

    {:noreply, new_state}
  end

  # Legacy 3-tuple key_press (frontends that predate the correlation sequence).
  def handle_info({:minga_input, {:key_press, codepoint, modifiers}}, state) do
    handle_info({:minga_input, {:key_press, codepoint, modifiers, 0}}, state)
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
    Log.info(:editor, "External change detected: #{path}")
    {new_state, effects} = FileEventHandler.handle(new_state, msg)
    {:noreply, EffectHandler.apply_effects(new_state, effects)}
  end

  def handle_info({:file_tree_filter_walk, _root, _filter, _entries} = msg, state) do
    {new_state, effects} = FileEventHandler.handle(state, msg)
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

  def handle_info({:minga_input, {:scroll_batch, window_id, delta_lines, direction}}, state) do
    snapshot = Input.Router.capture_snapshot(state)
    new_state = MingaEditor.Mouse.handle_scroll_batch(state, window_id, delta_lines, direction)
    new_state = Input.Router.post_action_housekeeping(new_state, snapshot)
    {:noreply, new_state}
  end

  # Legacy in-process fixtures omit generation; treat them as an explicit retry.
  def handle_info({:minga_input, {:request_keyframe, last_good_frame_seq}}, state) do
    handle_info({:minga_input, {:request_keyframe, last_good_frame_seq, 0}}, state)
  end

  def handle_info(
        {:minga_input, {:request_keyframe, last_good_frame_seq, failed_generation}},
        %{renderer: renderer, backend: backend} = state
      )
      when is_pid(renderer) and backend != :headless do
    Minga.Log.warning(
      :render,
      "Frontend requested recovery from frame #{last_good_frame_seq} generation #{failed_generation}"
    )

    MingaEditor.Renderer.Server.request_recovery(renderer)
    {:noreply, state}
  end

  def handle_info({:minga_input, {:request_keyframe, _last_good, _generation}}, state) do
    new_state = EditorState.request_render_keyframe(state)
    {:noreply, Renderer.render_or_async(new_state)}
  end

  def handle_info({:minga_input, {kind, _, _} = status}, %{renderer: renderer} = state)
      when kind == :frame_applied and is_pid(renderer) do
    MingaEditor.Renderer.Server.frame_status(renderer, status)
    {:noreply, state}
  end

  def handle_info({:minga_input, {kind, _, _, _, _} = status}, %{renderer: renderer} = state)
      when kind in [:frame_rejected, :window_ref_miss] and is_pid(renderer) do
    MingaEditor.Renderer.Server.frame_status(renderer, status)
    {:noreply, state}
  end

  # ── GUI action events (semantic commands from SwiftUI chrome) ────────────

  def handle_info({:minga_input, {:gui_action, action}}, state) do
    snapshot = Input.Router.capture_snapshot(state)

    # Span the synchronous dispatch so slow GUI actions still on the input path
    # surface as structured, aggregatable timing (issue #2357 AC7). Slow effects
    # admitted to the generation scheduler leave the span fast by design.
    new_state =
      Minga.Telemetry.span([:minga, :gui, :action], %{action: gui_action_tag(action)}, fn ->
        GuiActionHandler.dispatch(state, action)
      end)

    new_state = Input.Router.post_action_housekeeping(new_state, snapshot)
    {:noreply, new_state}
  end

  def handle_info({:whichkey_timeout, ref}, state) do
    if ref == state.shell_runtime.state.whichkey.timer do
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

  # A tick only *spawns* the collection Task and returns immediately, so the
  # blocking SystemObserver calls in Observatory.Collector.collect/1 never run on the
  # Editor mailbox. The next tick is scheduled when the result lands (see the
  # :observatory_data_result clause), not here, so a collection that takes
  # longer than the 1s interval is effectively skipped, never queued.
  def handle_info({:observatory_tick, token}, state) do
    if current_observatory_token?(state, token), do: spawn_observatory_collection(token)
    {:noreply, state}
  end

  def handle_info(:observatory_tick, state) do
    {:noreply, state}
  end

  # Async observatory data computed by the Task spawned on the matching tick.
  # Apply it cheaply (no blocking work here) and only now schedule the next
  # tick, which guarantees ticks are skipped-not-queued under slow collection.
  # A result carrying a stale token (panel closed, or a newer tick already
  # superseded this one) is dropped without scheduling anything.
  def handle_info({:observatory_data_result, token, data}, state) do
    if current_observatory_token?(state, token) do
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

  @lsp_format_timer_tags [:lsp_format_spinner, :lsp_format_cancellable, :lsp_format_timeout]

  def handle_info({tag, _ref} = msg, state) when tag in @lsp_format_timer_tags do
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

  # Correlated file-tree debounce timers enter the domain workflow directly.
  def handle_info({:file_tree_refresh_timer, token}, state) when is_reference(token) do
    {:noreply, MingaEditor.FileTree.Freshness.begin_refresh(state, token)}
  end

  # Renderer.Server writeback after each async frame completes.
  # EditorState narrows the merge to renderer-owned fields only.
  def handle_info({:render_done, %MingaEditor.Renderer.RenderReceipt{} = receipt}, state) do
    {:noreply, RenderHandler.handle_render_done(state, receipt)}
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
    Log.debug(:agent, "[event] #{inspect(event)}")
    route_agent_event(state, session_pid, event)
  end

  # Coalesced agent stream batch from MingaEditor.Agent.Ingest (#2289). One
  # batch replaces N per-delta messages: applied once (one bump_message_version,
  # one :sync_agent_transcript, one render) instead of once per delta, so streaming
  # load no longer floods the Editor mailbox ahead of queued keystrokes.
  def handle_info({:agent_stream_batch, session_pid, batch}, state) do
    route_agent_stream_batch(state, session_pid, batch)
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

  def handle_info({:compact_result, result}, state) do
    state = dispatch_agent_event(state, {:compact_result, result})
    {:noreply, Renderer.render_or_async(state)}
  end

  # Process died. Check buffer monitors and git remote tasks.
  # Agent session deaths are handled via :agent_session_stopped events from SessionManager.
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case classify_down(state, ref, pid, reason) do
      :buffer ->
        Log.info(:editor, "Buffer process #{inspect(pid)} died, removing from state")

        state =
          state
          |> HighlightSync.close_buffer(pid)
          |> EditorState.remove_dead_buffer(pid)

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

  def handle_info({:picker_fetch_candidates, source_module, revision, ctx}, state) do
    editor = self()

    Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
      result =
        try do
          case MingaEditor.UI.Picker.Source.fetch(source_module, ctx) do
            {:ok, items, meta} ->
              # Build the candidate cache here, off the editor process. The O(n)
              # normalization (downcase, grapheme split, search-text join) is the
              # work that froze the editor when a source returned 100K+ paths
              # (#2628); doing it in the Task means the editor handler only swaps
              # in the finished list instead of normalizing every path inline.
              {:ok, items, MingaEditor.UI.Picker.Candidate.from_items(items), meta}

            {:error, _reason} = error ->
              error
          end
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, "Source timed out: #{inspect(reason)}"}
          :throw, value -> {:error, "Source failed: #{inspect(value)}"}
        end

      send(editor, {:picker_candidates_result, source_module, revision, result})
    end)

    {:noreply, state}
  end

  # Latest-wins stale-result guard: a candidate fetch is applied only when the
  # live picker is still the same source *and* the result carries the picker's
  # current fetch revision. A newer search, project switch, reopen, or close
  # mints a new revision (or drops the picker), so older in-flight fetches land
  # here as stale and are discarded. Picker fetches retain this read-only
  # latest-wins path; #2805 migrates external formatting and git mutations.
  def handle_info({:picker_candidates_result, source_module, revision, result}, state) do
    case state.shell_runtime.state.modal do
      {:picker, %{picker_ui: %{source: ^source_module} = picker_ui} = payload} ->
        if MingaEditor.State.Picker.current_fetch?(picker_ui, revision) do
          new_state = handle_picker_candidates(state, payload, result)
          {:noreply, Renderer.render_or_async(new_state)}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  # ── Async completion processing result ──────────────────────────────────
  # LSP completion responses are parsed/sorted/filtered in a Task off the
  # Editor hot path (CompletionHandling.handle_response/3). The Task sends this
  # message back with the processed menu. apply_processed/5 applies it cheaply
  # and uses the generation token to discard a stale, superseded result
  # (latest-wins), so large completion sets never block input.
  def handle_info({:completion_processed, gen, mode, payload, trigger_pos}, state) do
    new_state = CompletionHandling.apply_processed(state, gen, mode, payload, trigger_pos)
    {:noreply, Renderer.render_or_async(new_state)}
  end

  # Slow-effect lifecycle and terminal candidates dispatch through the typed
  # request's domain handler. The Editor has no resource- or lane-specific switch.
  def handle_info({:effect_lifecycle, %Outcome{} = outcome}, state) do
    {new_state, final_outcome} = apply_effect_outcome(state, outcome)
    {:noreply, maybe_render_effect_outcome(new_state, final_outcome)}
  end

  def handle_info({:effect_result, scheduler, %Outcome{} = outcome}, state) do
    case EffectScheduler.claim(scheduler, outcome) do
      :ok ->
        {new_state, final_outcome} = apply_effect_outcome(state, outcome)
        EffectScheduler.finalize(scheduler, final_outcome)
        {:noreply, maybe_render_effect_outcome(new_state, final_outcome)}

      {:error, :not_pending} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec apply_effect_outcome(state(), Outcome.t()) :: {state(), Outcome.t()}
  defp apply_effect_outcome(state, %Outcome{request: %Request{handler: handler}} = outcome) do
    handler.apply(state, outcome)
  end

  @spec maybe_render_effect_outcome(state(), Outcome.t()) :: state()
  defp maybe_render_effect_outcome(state, %Outcome{request: %Request{handler: handler}} = outcome) do
    if handler.render?(outcome), do: Renderer.render_or_async(state), else: state
  end

  # Identifies the GUI action for the dispatch telemetry span (issue #2357 AC7),
  # so slow synchronous actions can be found by their tag without logging paths.
  @spec gui_action_tag(term()) :: atom()
  defp gui_action_tag(action) when is_atom(action), do: action

  defp gui_action_tag(action) when is_tuple(action) and tuple_size(action) > 0,
    do: elem(action, 0)

  defp gui_action_tag(_action), do: :unknown

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
          {:ok, [term()], [MingaEditor.UI.Picker.Candidate.t()],
           MingaEditor.UI.Picker.Source.fetch_meta()}
          | {:error, String.t()}
        ) :: state()
  defp handle_picker_candidates(state, payload, {:ok, items, candidates, meta}) do
    picker_state = payload.picker_ui
    # Candidates are pre-built by the fetch Task (#2628); the editor only swaps
    # them in here, so the input loop stays responsive on large directories.
    picker = MingaEditor.UI.Picker.put_candidates(picker_state.picker, items, candidates)
    new_picker_state = %{picker_state | picker: picker, load_status: :ready}

    state
    |> ModalOverlay.transition(:picker, PickerPayload.put_picker_ui(payload, new_picker_state))
    |> apply_fetch_status(meta)
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

  @spec apply_fetch_status(state(), MingaEditor.UI.Picker.Source.fetch_meta()) :: state()
  defp apply_fetch_status(state, %{status: status}) when is_binary(status) do
    EditorState.set_status(state, status)
  end

  defp apply_fetch_status(state, _meta), do: state

  @spec current_observatory_token?(state(), reference()) :: boolean()
  defp current_observatory_token?(
         %{
           shell_runtime: %{
             state: %{observatory_visible: true, observatory_timer: {_timer, token}}
           }
         },
         token
       ),
       do: true

  defp current_observatory_token?(_state, _token), do: false

  # Run the blocking SystemObserver collection in a supervised Task so the
  # Editor GenServer mailbox stays free. The token is echoed back with the
  # result so the receiving clause can drop stale collections. Observatory
  # .Collector.collect/1 is total, so the Task always sends a result and the
  # refresh tick always re-arms even when collection fails.
  @spec spawn_observatory_collection(reference()) :: :ok
  defp spawn_observatory_collection(token) do
    editor = self()

    Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
      send(editor, {:observatory_data_result, token, Observatory.Collector.collect()})
    end)

    :ok
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

  @doc """
  Rebuilds the cached native settings snapshot (#2119).

  The snapshot is emitted in-frame as the `config_state` semantic model, so this
  only refreshes the cached struct on `EditorState`; the next render delivers it
  inside the frame transaction. A keyframe re-emits it for free. For non-GUI
  frontends the snapshot stays nil and nothing is emitted.
  """
  @spec refresh_gui_config_state(EditorState.t()) :: EditorState.t()
  def refresh_gui_config_state(%{capabilities: caps} = state) do
    if MingaEditor.Frontend.gui?(caps) do
      snapshot =
        MingaEditor.Frontend.Protocol.GUI.config_state(
          EditorState.options_server(state),
          state.keymap_server
        )
        |> MingaEditor.RenderModel.UI.ConfigStateBuilder.from_wire()

      EditorState.put_gui_config_state(state, snapshot)
    else
      state
    end
  catch
    :exit, _ -> state
  end

  @spec apply_runtime_config_option(EditorState.t(), atom(), term()) :: EditorState.t()
  def apply_runtime_config_option(state, :theme, theme_name) when is_atom(theme_name) do
    theme = MingaEditor.UI.Theme.get!(theme_name)

    # No out-of-band theme push (#2119): applying the theme then invalidating every
    # window and the layout forces a full re-render, and the frame transaction's
    # ThemeEncoder re-emits gui_theme semantically (the new theme changes the
    # adapter cache fingerprint). A keyframe re-emits it for free. See
    # MingaEditor.RuntimeThemePushTest for the proof.
    state
    |> EditorState.apply_theme(theme)
    |> EditorState.invalidate_all_windows()
    |> Layout.invalidate()
  end

  def apply_runtime_config_option(state, name, _value)
      when name in [:font_family, :font_size, :font_weight, :font_ligatures] do
    state = %{state | font_size_override: nil}
    Startup.send_font_config(state)
    EditorState.reset_frontend_render_state(state)
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

  # Applies a coalesced stream batch (#2289). Mirrors route_agent_event owner
  # routing: the active foreground agent's batch mutates the agent surface once;
  # a background subagent's deltas carry no shell state (the shell only reacts to
  # control events, which Ingest forwards individually), so its batch just
  # schedules a render. Ephemeral inline sessions never route through Ingest.
  @spec route_agent_stream_batch(EditorState.t(), pid(), [term()]) :: {:noreply, EditorState.t()}
  defp route_agent_stream_batch(state, session_pid, batch) do
    route_agent_stream_batch(state, session_pid, batch, agent_event_owner(state, session_pid))
  end

  @spec route_agent_stream_batch(EditorState.t(), pid(), [term()], atom()) ::
          {:noreply, EditorState.t()}
  defp route_agent_stream_batch(state, _session_pid, batch, :active_agent) do
    {state, effects} = Events.handle_batch(state, batch)
    {:noreply, EffectHandler.apply_effects(state, effects)}
  end

  defp route_agent_stream_batch(state, _session_pid, _batch, _owner) do
    {:noreply, schedule_render(state, 16)}
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
    state = MingaEditor.Shell.Workflow.ensure_available(state)
    state = route_active_shell_agent_event(state, session_pid, event)
    state = route_stashed_shell_agent_event(state, session_pid, event)
    {:noreply, schedule_render(state, 16)}
  end

  @spec route_active_shell_agent_event(EditorState.t(), pid(), term()) :: EditorState.t()
  defp route_active_shell_agent_event(state, session_pid, event) do
    {runtime, workspace, effects, persistence_change} =
      MingaEditor.Shell.Runtime.route_agent_event(
        state.shell_runtime,
        state.workspace,
        session_pid,
        event
      )

    runtime = persist_shell_changes(runtime, List.wrap(persistence_change))

    state
    |> EditorState.apply_shell_runtime_transition(runtime)
    |> EditorState.set_workspace(workspace)
    |> EffectHandler.apply_effects(effects)
  end

  @spec route_stashed_shell_agent_event(EditorState.t(), pid(), term()) :: EditorState.t()
  defp route_stashed_shell_agent_event(state, session_pid, event) do
    {runtime, workspace, effects, persistence_changes} =
      MingaEditor.Shell.Runtime.route_stashed_agent_event(
        state.shell_runtime,
        MingaEditor.Shell.Workflow.resolved_entries(),
        state.workspace,
        session_pid,
        event
      )

    runtime = persist_shell_changes(runtime, persistence_changes)

    state
    |> EditorState.apply_shell_runtime_transition(runtime)
    |> EditorState.set_workspace(workspace)
    |> EffectHandler.apply_effects(effects)
  end

  @spec persist_shell_changes(
          MingaEditor.Shell.Runtime.t(),
          [MingaEditor.Shell.Runtime.persistence_change()]
        ) :: MingaEditor.Shell.Runtime.t()
  defp persist_shell_changes(runtime, changes) do
    Enum.reduce(changes, runtime, fn {entry, _old_state, new_state}, runtime_acc ->
      persisted_state = persist_shell_state(entry.module, new_state)
      MingaEditor.Shell.Runtime.accept_persisted_state(runtime_acc, entry, persisted_state)
    end)
  end

  @spec persist_shell_state(module(), MingaEditor.Shell.shell_state()) ::
          MingaEditor.Shell.shell_state()
  defp persist_shell_state(module, shell_state) do
    if function_exported?(module, :persist_shell_state, 1),
      do: module.persist_shell_state(shell_state),
      else: shell_state
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
  # handler clears the correlation owner's timer so the next event after the window can
  # schedule again.
  #
  # For streaming agent responses, this ensures new text is visible within
  # one frame (~16ms) of arriving at the BEAM, because:
  # 1. First delta triggers an immediate or near-immediate render.
  # 2. Deltas arriving mid-window are picked up by the pending timer.
  # 3. The timer fires, renders the latest state, and clears the guard
  #    so the next delta can schedule again.
  # apply_textobject_positions moved to HighlightHandler

  @spec schedule_render_delay_ms(state(), non_neg_integer()) :: non_neg_integer()
  def schedule_render_delay_ms(%EditorState{} = state, delay_ms)
      when is_integer(delay_ms) and delay_ms >= 0 do
    max(delay_ms, ResourcePressure.render_delay_ms(state.resource_pressure))
  end

  @spec schedule_render(state(), non_neg_integer()) :: state()
  def schedule_render(%EditorState{} = state, delay_ms)
      when is_integer(delay_ms) and delay_ms >= 0 do
    if EditorState.render_scheduled?(state), do: state, else: schedule_new_render(state, delay_ms)
  end

  # In test mode (headless backend), render synchronously to eliminate timer
  # races that cause CI flakiness. No debounce needed when there's no real
  # display to coalesce frames for.
  @spec schedule_new_render(state(), non_neg_integer()) :: state()
  defp schedule_new_render(%{backend: :headless} = state, _delay_ms) do
    state = RenderHandler.maybe_trigger_nav_flash(state)
    state = Renderer.render_or_async(state)
    EditorState.clear_render_timer(state)
  end

  defp schedule_new_render(state, delay_ms) do
    effective_delay_ms = schedule_render_delay_ms(state, delay_ms)
    ref = Process.send_after(self(), :debounced_render, effective_delay_ms)
    EditorState.schedule_render_timer(state, ref)
  end

  # LSP status aggregation moved to MingaEditor.State.LSP

  # ── Diagnostic decorations ──────────────────────────────────────────────────

  # Applies diagnostic underline decorations to the buffer matching the URI.
  # Called when {:minga_event, :diagnostics_updated, ...} arrives via the event bus.
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
  @spec reset_nav_flash_tracking(state()) :: state()
  def reset_nav_flash_tracking(state) do
    state = cancel_nav_flash(state)
    %{state | last_cursor_line: nil}
  end

  # Cancels any active nav-flash. Called on every keypress.
  @spec cancel_nav_flash(state()) :: state()
  def cancel_nav_flash(%{shell_runtime: %{state: %{nav_flash: nil}}} = state), do: state

  def cancel_nav_flash(state) do
    effects = NavFlash.cancel_effects(EditorState.nav_flash(state))
    MingaEditor.FlashEffects.execute(state, effects)
    EditorState.cancel_nav_flash(state)
  end

  @spec cancel_yank_flash(state()) :: state()
  def cancel_yank_flash(%{shell_runtime: %{state: %{yank_flash: nil}}} = state), do: state

  def cancel_yank_flash(%{shell_runtime: %{state: %{yank_flash: flash}}} = state) do
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
    Log.info(:editor, "Paste ignored (no active buffer)")
    state
  end

  # ── Tool picker refresh ─────────────────────────────────────────────

  # Refreshes the tool manager picker items if it's currently open.
  # Called when tool install events change tool status so the user
  # sees live updates (spinner -> checkmark, etc.).
  @spec maybe_refresh_tool_picker(state()) :: state()
  def maybe_refresh_tool_picker(
        %{
          shell_runtime: %{
            state: %{
              modal: {:picker, %{picker_ui: %{source: MingaEditor.UI.Picker.Sources.Tool}}}
            }
          }
        } = state
      ) do
    MingaEditor.PickerUI.refresh_items(state)
  end

  def maybe_refresh_tool_picker(state), do: state

  @spec resolve_git_root() :: String.t() | nil
  def resolve_git_root do
    root = Minga.Project.resolve_root()

    case Minga.Git.root_for(root) do
      {:ok, git_root} -> git_root
      :not_git -> nil
    end
  end

  @spec refresh_git_repo(String.t()) :: :ok
  def refresh_git_repo(git_root) do
    case Git.lookup_repo(git_root) do
      nil -> :ok
      pid -> Git.Repo.refresh(pid)
    end
  end

  # ── Warning popup debounce ───────────────────────────────────────────────

  @warning_popup_debounce_ms 200

  @spec maybe_schedule_warning_popup(state()) :: state()
  def maybe_schedule_warning_popup(
        %{shell_runtime: %{state: %{warning_popup_timer: ref}}} = state
      )
      when is_reference(ref) do
    # Timer already running; the pending timeout will open the popup.
    state
  end

  def maybe_schedule_warning_popup(%{backend: :headless} = state), do: state

  def maybe_schedule_warning_popup(state) do
    ref = Process.send_after(self(), :warning_popup_timeout, @warning_popup_debounce_ms)
    EditorState.set_warning_popup_timer(state, ref)
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

  @spec do_render(state()) :: state()
  def do_render(state) do
    Renderer.render_or_async(state)
  end

  @doc false
  @spec do_dismiss_completion(state()) :: state()
  defdelegate do_dismiss_completion(state), to: CompletionHandling, as: :dismiss
end
