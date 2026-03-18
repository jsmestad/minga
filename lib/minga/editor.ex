defmodule Minga.Editor do
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

  alias Minga.Agent.Events
  alias Minga.Agent.UIState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Completion
  alias Minga.Config.Options
  alias Minga.Editor.AgentLifecycle
  alias Minga.Editor.BufferLifecycle
  alias Minga.Editor.Commands
  alias Minga.Editor.CompletionHandling
  alias Minga.Editor.CompletionTrigger

  alias Minga.Editor.FileWatcherHelpers
  alias Minga.Editor.FoldRange
  alias Minga.Editor.HighlightEvents
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.KeyDispatch
  alias Minga.Editor.Layout
  alias Minga.Editor.LspActions
  alias Minga.Editor.MessageLog
  alias Minga.Editor.NavFlash
  alias Minga.Editor.Renderer
  alias Minga.Editor.Startup
  alias Minga.Editor.Viewport
  alias Minga.Editor.WarningLog
  alias Minga.Editor.Window
  alias Minga.FileTree
  alias Minga.Input
  alias Minga.Mode
  alias Minga.Popup.Lifecycle, as: PopupLifecycle
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol

  @typedoc "Options for starting the editor."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:port_manager, GenServer.server()}
          | {:buffer, pid()}
          | {:width, pos_integer()}
          | {:height, pos_integer()}

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar

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

    # Logger redirect and startup messages
    tui_active? = state.port_manager == PortManager

    state =
      if tui_active? do
        log_path = Minga.LoggerHandler.install()
        state = log_message(state, "Editor started")
        log_message(state, "Log file: #{log_path}")
      else
        log_message(state, "Editor started")
      end

    # Flush any log messages that arrived while the Editor was down
    # (e.g., supervisor crash reports from a previous Editor crash).
    # Must happen after *Messages* buffer is ready but before we return.
    flushed = Minga.LoggerHandler.flush_buffer()

    state =
      if flushed > 0 do
        log_message(state, "Replayed #{flushed} message(s) from before restart")
      else
        state
      end

    state = Startup.apply_config_options(state)
    Minga.Diagnostics.subscribe()

    # Refresh file tree git status when any buffer is saved.
    Minga.Events.subscribe(:buffer_saved)

    # Monitor all initial buffers so we get :DOWN when they die.
    all_initial_pids =
      state.buffers.list ++
        Enum.filter(
          [state.buffers.messages, state.buffers.warnings, state.buffers.help],
          &is_pid/1
        )

    state = EditorState.monitor_buffers(state, all_initial_pids)

    # Schedule periodic eviction of inactive tree-sitter parse trees.
    Process.send_after(self(), :evict_parser_trees, HighlightSync.eviction_check_interval_ms())

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
    # Only uninstall if we installed (i.e. real TUI, not headless test).
    # Check for our handler presence rather than storing state.
    case :logger.get_handler_config(:minga_messages) do
      {:ok, _} -> Minga.LoggerHandler.uninstall()
      _ -> :ok
    end

    :ok
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:open_file, file_path}, _from, state) do
    case Commands.start_buffer(file_path) do
      {:ok, pid} ->
        new_state = register_buffer(state, pid, file_path)
        new_state = AgentLifecycle.maybe_set_auto_context(new_state, file_path, pid)
        new_state = Renderer.render(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:api_active_buffer, _from, %{buffers: %{active: nil}} = state) do
    {:reply, {:error, :no_buffer}, state}
  end

  def handle_call(:api_active_buffer, _from, %{buffers: %{active: buf}} = state) do
    {:reply, {:ok, buf}, state}
  end

  def handle_call(:api_mode, _from, state) do
    {:reply, state.vim.mode, state}
  end

  def handle_call(:api_save, _from, %{buffers: %{active: nil}} = state) do
    {:reply, {:error, :no_buffer}, state}
  end

  def handle_call(:api_save, _from, %{buffers: %{active: buf}} = state) do
    result = BufferServer.save(buf)

    new_state =
      case result do
        :ok ->
          log_message(state, "Saved: #{Commands.Helpers.buffer_display_name(buf)}")

        _ ->
          state
      end

    new_state = Renderer.render(new_state)
    {:reply, result, new_state}
  end

  def handle_call({:api_execute_command, cmd}, _from, state) do
    new_state = dispatch_command(state, cmd)
    new_state = Renderer.render(new_state)
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

    new_state = Renderer.render(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:api_log_message, text}, _from, state) do
    new_state = log_message(state, text)
    {:reply, :ok, new_state}
  end

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:log_to_messages, text}, state) do
    {:noreply, log_message(state, text)}
  end

  def handle_cast({:log_to_warnings, text}, state) do
    state = WarningLog.log(state, text)
    {:noreply, maybe_schedule_warning_popup(state)}
  end

  def handle_cast({:extension_updates_available, updates}, state) do
    alias Minga.Mode.ExtensionConfirmState

    ms = %ExtensionConfirmState{updates: updates}
    new_state = %{state | vim: %{state.vim | mode: :extension_confirm, mode_state: ms}}
    new_state = Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:render, state) do
    state = Renderer.render(state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:minga_input, {:ready, width, height}}, state) do
    # Query capabilities from the frontend (may have been sent in extended ready).
    caps = Startup.fetch_capabilities(state.port_manager)
    new_state = %{state | viewport: Viewport.new(height, width), capabilities: caps, layout: nil}
    Startup.send_font_config(new_state)
    new_state = Renderer.render(new_state)
    # Setup highlighting after first paint with correct viewport
    send(self(), :setup_highlight)
    # If the agentic view was activated at init, start the session now
    # that the port is connected and the viewport is known.
    new_state = AgentLifecycle.maybe_start_session(new_state)
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
    new_state = %{state | viewport: Viewport.new(height, width)}
    # Invalidate the cached layout so resize_all_windows computes fresh
    # rectangles from the new viewport dimensions.
    new_state = Layout.invalidate(new_state)
    new_state = resize_all_windows(new_state)
    new_state = Renderer.render(new_state)
    {:noreply, new_state}
  end

  # ── Key press dispatch ──
  # All key presses go through the focus stack via Input.Router.
  # The router walks ConflictPrompt → Picker → Completion → GlobalBindings → ModeFSM
  # and runs centralized post-key housekeeping (highlight sync, reparse,
  # completion, render) exactly once.
  def handle_info({:minga_input, {:key_press, codepoint, modifiers}}, state) do
    state = cancel_nav_flash(state)

    new_state =
      Minga.Telemetry.span([:minga, :input, :dispatch], %{}, fn ->
        Input.Router.dispatch(state, codepoint, modifiers)
      end)

    {:noreply, new_state}
  end

  # ── Paste event (bracketed paste from TUI, Cmd+V from GUI) ──
  def handle_info({:minga_input, {:paste_event, text}}, state) do
    new_state = handle_paste_event(state, text)
    new_state = Renderer.render(new_state)
    {:noreply, new_state}
  end

  # ── File watcher notification ──
  def handle_info({:file_changed_on_disk, path}, state) do
    new_state = FileWatcherHelpers.handle_file_change(state, path)
    new_state = log_message(new_state, "External change detected: #{path}")
    new_state = Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info(
        {:minga_input, {:mouse_event, row, col, button, mods, event_type, click_count}},
        state
      ) do
    new_state =
      Input.Router.dispatch_mouse(state, row, col, button, mods, event_type, click_count)

    new_state = Renderer.render(new_state)
    {:noreply, new_state}
  end

  # Backward compat: 6-element mouse_event (no click_count)
  def handle_info(
        {:minga_input, {:mouse_event, row, col, button, mods, event_type}},
        state
      ) do
    new_state = Input.Router.dispatch_mouse(state, row, col, button, mods, event_type, 1)
    new_state = Renderer.render(new_state)
    {:noreply, new_state}
  end

  # ── GUI action events (semantic commands from SwiftUI chrome) ────────────

  def handle_info({:minga_input, {:gui_action, action}}, state) do
    new_state = handle_gui_action(state, action)
    new_state = Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:whichkey_timeout, ref}, %{whichkey: %{timer: ref}} = state) do
    new_state = put_in(state.whichkey.show, true)
    new_state = Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:whichkey_timeout, _ref}, state) do
    # Stale timer — ignore.
    {:noreply, state}
  end

  # ── Highlight setup (async, after first paint with correct viewport) ──────────

  def handle_info(:setup_highlight, state) do
    new_state = HighlightSync.setup_for_buffer(state)
    {:noreply, new_state}
  end

  # ── Highlight events from Parser.Manager ──────────────────────────────────────
  # These arrive as {:minga_highlight, event} from the dedicated parser process.
  # Legacy {:minga_input, event} forms are also accepted for backward
  # compatibility during the transition (headless tests, etc.).

  def handle_info({tag, {:highlight_names, buffer_id, names}}, state)
      when tag in [:minga_highlight, :minga_input] do
    # Resolve buffer_id to PID; fall back to active buffer for unregistered IDs
    # (e.g., buffer_id 0 from test injection or legacy code paths).
    pid = HighlightSync.resolve_buffer_pid(state, buffer_id) || state.buffers.active

    new_state =
      if pid == state.buffers.active do
        HighlightEvents.handle_names(state, names)
      else
        existing = HighlightSync.get_highlight(state, pid)
        updated = Minga.Highlight.put_names(existing, names)
        HighlightSync.put_highlight(state, pid, updated)
      end

    {:noreply, new_state}
  end

  def handle_info({tag, {:injection_ranges, buffer_id, ranges}}, state)
      when tag in [:minga_highlight, :minga_input] do
    pid = HighlightSync.resolve_buffer_pid(state, buffer_id) || state.buffers.active

    new_state =
      if pid do
        %{state | injection_ranges: Map.put(state.injection_ranges, pid, ranges)}
      else
        state
      end

    {:noreply, new_state}
  end

  def handle_info({tag, {:language_at_response, _request_id, _language}}, state)
      when tag in [:minga_highlight, :minga_input] do
    {:noreply, state}
  end

  def handle_info({tag, {:highlight_spans, buffer_id, version, spans}}, state)
      when tag in [:minga_highlight, :minga_input] do
    pid = HighlightSync.resolve_buffer_pid(state, buffer_id) || state.buffers.active

    new_state =
      if pid == state.buffers.active do
        HighlightEvents.handle_spans(state, version, spans)
      else
        # Non-active buffer: store spans in highlights map.
        existing = HighlightSync.get_highlight(state, pid)
        updated = Minga.Highlight.put_spans(existing, version, spans)
        state_with_hl = HighlightSync.put_highlight(state, pid, updated)

        # If this buffer is visible in any window (e.g., agent panel),
        # trigger a render so the highlights appear immediately.
        if buffer_visible_in_window?(state_with_hl, pid) do
          Renderer.render(state_with_hl)
        else
          state_with_hl
        end
      end

    {:noreply, new_state}
  end

  def handle_info({tag, {:fold_ranges, buffer_id, _version, ranges}}, state)
      when tag in [:minga_highlight, :minga_input] do
    Minga.Log.debug(:editor, "Fold ranges received: buffer=#{buffer_id}, count=#{length(ranges)}")

    pid = HighlightSync.resolve_buffer_pid(state, buffer_id) || state.buffers.active

    new_state =
      if pid == state.buffers.active do
        fold_ranges =
          Enum.map(ranges, fn {start_line, end_line} ->
            FoldRange.new!(start_line, end_line)
          end)

        case EditorState.active_window_struct(state) do
          nil ->
            state

          %Window{id: id} ->
            EditorState.update_window(state, id, &Window.set_fold_ranges(&1, fold_ranges))
        end
      else
        # Stale response for a non-active buffer; discard.
        state
      end

    {:noreply, new_state}
  end

  def handle_info({tag, {:textobject_positions, buffer_id, _version, positions}}, state)
      when tag in [:minga_highlight, :minga_input] do
    pid = HighlightSync.resolve_buffer_pid(state, buffer_id) || state.buffers.active

    new_state =
      if pid == state.buffers.active do
        apply_textobject_positions(state, positions)
      else
        # Stale response for a non-active buffer; discard.
        state
      end

    {:noreply, new_state}
  end

  def handle_info({tag, {:grammar_loaded, true, name}}, state)
      when tag in [:minga_highlight, :minga_input] do
    Minga.Log.info(:editor, "Grammar loaded: #{name}")
    {:noreply, state}
  end

  def handle_info({tag, {:grammar_loaded, false, name}}, state)
      when tag in [:minga_highlight, :minga_input] do
    Minga.Log.warning(:editor, "Grammar failed to load: #{name}")
    {:noreply, state}
  end

  def handle_info({:minga_input, {:log_message, level, text}}, state) do
    prefix = MessageLog.frontend_prefix(state)
    new_state = log_message(state, "[#{prefix}/#{level}] #{text}")
    {:noreply, new_state}
  end

  # Parser log messages (routed over the protocol, same format as renderer logs).
  def handle_info({:minga_highlight, {:log_message, level, text}}, state) do
    new_state = log_message(state, "[PARSER/#{level}] #{text}")
    {:noreply, new_state}
  end

  # Parser process crashed; Manager is scheduling a restart.
  def handle_info({:minga_highlight, :parser_crashed}, state) do
    {:noreply, %{state | parser_status: :restarting}}
  end

  # Parser recovered after a crash; buffer re-sync already happened in Manager.
  # Reset both the global highlight version AND each per-buffer highlight's
  # version to 0 so resync spans (sent at version 0) pass the version guard
  # in Highlight.put_spans/3. Without resetting per-buffer versions, the
  # resync spans would be silently discarded (0 < previous_version).
  def handle_info({:minga_highlight, :parser_restarted}, state) do
    hl = state.highlight

    reset_highlights =
      Map.new(hl.highlights, fn {pid, buf_hl} ->
        {pid, %{buf_hl | version: 0}}
      end)

    new_state = %{
      state
      | highlight: %{hl | version: 0, highlights: reset_highlights},
        parser_status: :available
    }

    new_state = log_message(new_state, "Parser restarted, syntax highlighting recovered")
    {:noreply, new_state}
  end

  # Parser gave up retrying after repeated crashes.
  def handle_info({:minga_highlight, :parser_gave_up}, state) do
    new_state = %{state | parser_status: :unavailable}

    new_state =
      log_message(
        new_state,
        "Parser crashed repeatedly, syntax highlighting disabled. Use :parser-restart to retry."
      )

    {:noreply, new_state}
  end

  # ── LRU eviction of inactive parser trees ─────────────────────────────────────

  def handle_info(:evict_parser_trees, state) do
    ttl_seconds = Options.get(:parser_tree_ttl)
    # Protect the agent buffer from eviction: it's persistent and always-visible.
    agent_buf = state |> EditorState.AgentAccess.agent() |> Map.get(:buffer)
    protected = if is_pid(agent_buf), do: [agent_buf], else: []

    state =
      HighlightSync.evict_inactive(state,
        ttl_ms: ttl_seconds * 1_000,
        protected_pids: protected
      )

    Process.send_after(self(), :evict_parser_trees, HighlightSync.eviction_check_interval_ms())
    {:noreply, state}
  end

  # Completion debounce timer fired — send the actual completion request
  def handle_info({:completion_debounce, client, buffer_pid}, state) do
    new_bridge = CompletionTrigger.flush_debounce(state.completion_trigger, client, buffer_pid)
    {:noreply, %{state | completion_trigger: new_bridge}}
  end

  # LSP async response — route to the appropriate handler based on lsp.pending
  def handle_info({:lsp_response, ref, result}, state) do
    case Map.pop(state.lsp_pending, ref) do
      {:definition, pending} ->
        new_state = put_in(state.lsp_pending, pending)
        new_state = LspActions.handle_definition_response(new_state, result)
        new_state = Renderer.render(new_state)
        {:noreply, new_state}

      {:hover, pending} ->
        new_state = put_in(state.lsp_pending, pending)
        new_state = LspActions.handle_hover_response(new_state, result)
        new_state = Renderer.render(new_state)
        {:noreply, new_state}

      {:completion_resolve, pending} ->
        new_state = put_in(state.lsp_pending, pending)
        new_state = CompletionHandling.handle_resolve_response(new_state, result)
        new_state = Renderer.render(new_state)
        {:noreply, new_state}

      {:signature_help, pending} ->
        new_state = put_in(state.lsp_pending, pending)
        new_state = CompletionHandling.handle_signature_help_response(new_state, result)
        new_state = Renderer.render(new_state)
        {:noreply, new_state}

      {nil, _} ->
        # Not a tracked request — try completion handler
        handle_lsp_completion_response(ref, result, state)
    end
  end

  # Completion resolve debounce timer fired — send the actual resolve request
  def handle_info({:completion_resolve, index}, state) do
    state = CompletionHandling.flush_resolve(state, index)
    {:noreply, state}
  end

  # Refresh the cached LSP status for the modeline indicator.
  # Fired after buffer open (with delay for async LSP initialization)
  # and periodically while LSP clients are connecting.
  def handle_info(:refresh_lsp_status, state) do
    old_status = state.lsp_status
    state = BufferLifecycle.refresh_lsp_status(state)

    # If still initializing/starting, check again in 1 second
    if state.lsp_status in [:starting, :initializing] do
      Process.send_after(self(), :refresh_lsp_status, 1_000)
    end

    # Re-render if status changed (modeline needs update)
    state = if state.lsp_status != old_status, do: schedule_render(state, 16), else: state
    {:noreply, state}
  end

  # Diagnostics changed — re-render to update gutter signs and minibuffer hint.
  # Debounced because multiple diagnostics may arrive in rapid succession.
  def handle_info({:diagnostics_changed, _uri}, state) do
    {:noreply, schedule_render(state, 16)}
  end

  # Debounced render timer fired — perform the actual render.
  def handle_info(:debounced_render, state) do
    state = maybe_trigger_nav_flash(state)
    state = Renderer.render(state)
    {:noreply, %{state | render_timer: nil}}
  end

  # Nav-flash timer step — advance the fade or clear the flash.
  def handle_info(:nav_flash_step, %{nav_flash: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:nav_flash_step, %{nav_flash: flash} = state) do
    case NavFlash.advance(flash) do
      {:continue, updated, effects} ->
        state = %{state | nav_flash: apply_flash_effects(updated, effects)}
        state = Renderer.render(state)
        {:noreply, state}

      :done ->
        state = %{state | nav_flash: nil}
        state = Renderer.render(state)
        {:noreply, state}
    end
  end

  # Warning popup debounce timer fired — open the *Warnings* popup if not
  # already visible.
  def handle_info(:warning_popup_timeout, state) do
    state = %{state | warning_popup_timer: nil}
    {:noreply, open_warnings_popup_if_needed(state)}
  end

  # ── Agent events ──────────────────────────────────────────────────────────
  #
  # All agent events are tagged with the session pid so we can route them
  # Agent events are handled directly via Agent.Events, which reads and
  # writes agent/agentic fields on EditorState directly.

  def handle_info({:agent_event, session_pid, event}, state) do
    Minga.Log.debug(:agent, "[event] #{inspect(event)}")

    if AgentAccess.session(state) == session_pid do
      state = dispatch_agent_event(state, event)
      {:noreply, state}
    else
      # Background tab: update tab metadata and attention. The Session
      # process holds the real state; we only track status and attention
      # on the Tab struct for tab bar rendering.
      state = update_background_tab_status(state, session_pid, event)
      state = maybe_set_background_attention(state, session_pid, event)
      {:noreply, state}
    end
  end

  def handle_info(:agent_spinner_tick, state) do
    state = dispatch_agent_event(state, :spinner_tick)
    {:noreply, state}
  end

  # Process died. Check agent session first, then buffer monitors.
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      AgentAccess.session(state) == pid and AgentAccess.agent(state).session_monitor == ref ->
        Minga.Log.error(
          :agent,
          "[Agent] Session #{inspect(pid)} terminated: #{inspect(reason, pretty: true, limit: 500)}"
        )

        state = AgentAccess.update_agent(state, &AgentState.clear_session/1)
        state = %{state | status_msg: "Agent session terminated, SPC a n to restart"}
        {:noreply, state}

      Map.has_key?(state.buffer_monitors, pid) ->
        Minga.Log.info(:editor, "Buffer process #{inspect(pid)} died, removing from state")
        state = EditorState.remove_dead_buffer(state, pid)
        {:noreply, Renderer.render(state)}

      true ->
        {:noreply, state}
    end
  end

  @toast_duration_ms 3_000

  def handle_info(:dismiss_toast, state) do
    state = dispatch_agent_event(state, :dismiss_toast)

    if UIState.toast_visible?(AgentAccess.agent_ui(state)) do
      Process.send_after(self(), :dismiss_toast, @toast_duration_ms)
    end

    {:noreply, state}
  end

  def handle_info({:minga_event, :buffer_saved, %Minga.Events.BufferEvent{}}, state) do
    {:noreply, refresh_tree_git_status(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Agent event dispatch ──────────────────────────────────────────────────

  @spec dispatch_agent_event(EditorState.t(), term()) :: EditorState.t()
  defp dispatch_agent_event(state, event) do
    {state, effects} = Events.handle(state, event)
    apply_effects(state, effects)
  end

  # Updates a background agent tab's metadata from a session event.
  # The Session process holds the real state; we only track status on
  # the Tab struct so the tab bar can render status indicators.
  @spec update_background_tab_status(EditorState.t(), pid(), term()) :: EditorState.t()
  defp update_background_tab_status(state, session_pid, {:status_changed, status}) do
    case state.tab_bar && TabBar.find_by_session(state.tab_bar, session_pid) do
      %Tab{id: id} ->
        tb = TabBar.update_tab(state.tab_bar, id, &Tab.set_agent_status(&1, status))
        %{state | tab_bar: tb}

      _ ->
        state
    end
  end

  defp update_background_tab_status(state, _session_pid, _event), do: state

  # Sets the attention flag on a background agent tab when the session
  # reaches a state that needs user input. Derived from domain events;
  # the Session process doesn't know about UI attention.
  @spec maybe_set_background_attention(EditorState.t(), pid(), term()) :: EditorState.t()
  defp maybe_set_background_attention(state, session_pid, {:status_changed, status})
       when status in [:idle, :error] do
    set_tab_attention(state, session_pid)
  end

  defp maybe_set_background_attention(state, session_pid, {:approval_pending, _}) do
    set_tab_attention(state, session_pid)
  end

  defp maybe_set_background_attention(state, _session_pid, _event), do: state

  @spec set_tab_attention(EditorState.t(), pid()) :: EditorState.t()
  defp set_tab_attention(state, session_pid) do
    case state.tab_bar && TabBar.find_by_session(state.tab_bar, session_pid) do
      nil ->
        state

      _tab ->
        %{state | tab_bar: TabBar.set_attention_by_session(state.tab_bar, session_pid, true)}
    end
  end

  # ── Agent lifecycle ──────────────────────────────────────────────────────

  @typedoc """
  Side effects returned by agent event handlers.

  * `:render` — schedule a debounced render
  * `{:render, delay_ms}` — schedule render with custom delay
  * `{:open_file, path}` — open a file in a new or existing buffer
  * `{:switch_buffer, pid}` — make this buffer active
  * `{:set_status, msg}` — show a status message in the minibuffer
  * `{:push_overlay, module}` — push an overlay handler onto the focus stack
  * `{:pop_overlay, module}` — pop an overlay handler from the focus stack
  * `{:log_message, msg}` — log to *Messages* buffer
  * `{:log_warning, msg}` — log to both *Messages* and *Warnings* (warning level)
  * `:sync_agent_buffer` — sync agent buffer with session output
  * `{:update_tab_label, label}` — update active tab label
  """
  @type effect ::
          :render
          | {:render, delay_ms :: pos_integer()}
          | {:open_file, String.t()}
          | {:switch_buffer, pid()}
          | {:set_status, String.t()}
          | {:push_overlay, module()}
          | {:pop_overlay, module()}
          | {:log_message, String.t()}
          | {:log_warning, String.t()}
          | :sync_agent_buffer
          | {:update_tab_label, String.t()}

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
  defp apply_effect(state, {:set_status, msg}) when is_binary(msg), do: %{state | status_msg: msg}

  defp apply_effect(state, {:open_file, path}) when is_binary(path),
    do: Commands.execute(state, {:edit_file, path})

  defp apply_effect(state, {:switch_buffer, pid}) when is_pid(pid) do
    case Enum.find_index(state.buffers.list, &(&1 == pid)) do
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
    state
  end

  defp apply_effect(state, :sync_agent_buffer), do: AgentLifecycle.sync_buffer(state)

  defp apply_effect(state, {:update_tab_label, _label}),
    do: AgentLifecycle.maybe_update_tab_label(state)

  # Tab bar, view state, capabilities, parser subscription helpers

  # Agent lifecycle helpers (session startup, auto-context, buffer sync,

  @spec handle_lsp_completion_response(reference(), term(), state()) :: {:noreply, state()}
  defp handle_lsp_completion_response(ref, result, state) do
    new_state = CompletionHandling.handle_response(state, ref, result)
    new_state = Renderer.render(new_state)
    {:noreply, new_state}
  end

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
  @spec apply_textobject_positions(state(), map()) :: state()
  defp apply_textobject_positions(state, positions) do
    case EditorState.active_window_struct(state) do
      nil ->
        state

      %Window{id: id} ->
        EditorState.update_window(state, id, &%{&1 | textobject_positions: positions})
    end
  end

  @spec schedule_render(state(), non_neg_integer()) :: state()
  defp schedule_render(%{render_timer: ref} = state, _delay_ms) when is_reference(ref), do: state

  defp schedule_render(state, delay_ms) do
    ref = Process.send_after(self(), :debounced_render, delay_ms)
    %{state | render_timer: ref}
  end

  # ── Nav-flash detection ───────────────────────────────────────────────────────

  # Checks if the cursor jumped far enough to trigger a nav-flash.
  # Updates `last_cursor_line` and, when the threshold is exceeded,
  # starts (or restarts) the flash animation.
  @spec maybe_trigger_nav_flash(state()) :: state()
  defp maybe_trigger_nav_flash(%{buffers: %{active: nil}} = state), do: state

  defp maybe_trigger_nav_flash(state) do
    buf = state.buffers.active
    {current_line, _col} = BufferServer.cursor(buf)

    state = detect_jump(state, current_line)
    %{state | last_cursor_line: current_line}
  end

  @spec detect_jump(state(), non_neg_integer()) :: state()
  defp detect_jump(%{last_cursor_line: nil} = state, _current_line), do: state

  defp detect_jump(state, current_line) do
    delta = abs(current_line - state.last_cursor_line)
    threshold = Options.get(:nav_flash_threshold)

    if delta >= threshold and Options.get(:nav_flash) do
      start_flash(state, current_line)
    else
      cancel_flash_if_active(state)
    end
  end

  @spec start_flash(state(), non_neg_integer()) :: state()
  defp start_flash(state, line) do
    old_timer = if state.nav_flash, do: state.nav_flash.timer, else: nil
    {flash, effects} = NavFlash.start(line, old_timer)
    %{state | nav_flash: apply_flash_effects(flash, effects)}
  end

  @spec cancel_flash_if_active(state()) :: state()
  defp cancel_flash_if_active(%{nav_flash: nil} = state), do: state

  defp cancel_flash_if_active(state) do
    effects = NavFlash.cancel_effects(state.nav_flash)
    execute_flash_effects(effects)
    %{state | nav_flash: nil}
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
  defp cancel_nav_flash(%{nav_flash: nil} = state), do: state

  defp cancel_nav_flash(state) do
    effects = NavFlash.cancel_effects(state.nav_flash)
    execute_flash_effects(effects)
    %{state | nav_flash: nil}
  end

  # Executes side effects from NavFlash and returns the flash struct
  # with the timer reference filled in.
  @spec apply_flash_effects(NavFlash.t(), [NavFlash.side_effect()]) :: NavFlash.t()
  defp apply_flash_effects(flash, effects) do
    Enum.reduce(effects, flash, fn
      {:send_after, msg, interval}, acc ->
        ref = Process.send_after(self(), msg, interval)
        %{acc | timer: ref}

      {:cancel_timer, ref}, acc ->
        Process.cancel_timer(ref)
        acc
    end)
  end

  # Executes side effects without updating a flash struct (for cancellation).
  @spec execute_flash_effects([NavFlash.side_effect()]) :: :ok
  defp execute_flash_effects(effects) do
    Enum.each(effects, fn
      {:cancel_timer, ref} -> Process.cancel_timer(ref)
      {:send_after, msg, interval} -> Process.send_after(self(), msg, interval)
    end)
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
  defp handle_paste_event_editor(%{vim: %{mode: :insert}, buffers: %{active: buf}} = state, text)
       when is_pid(buf) do
    {line, col} = BufferServer.cursor(buf)
    BufferServer.apply_text_edit(buf, line, col, line, col, text)
    state
  end

  defp handle_paste_event_editor(state, _text) do
    log_message(state, "Paste ignored (not in insert mode or agent input)")
  end

  # ── File tree helpers ───────────────────────────────────────────────────

  @doc false
  @spec do_file_tree_open(state(), pid(), String.t(), FileTree.t()) :: state()
  def do_file_tree_open(state, pid, path, tree) do
    new_state = register_buffer(state, pid, path)
    put_in(new_state.file_tree.tree, FileTree.reveal(tree, path))
  end

  # Shared buffer registration: adds buffer to the list, logs, refreshes
  # LSP status, and broadcasts :buffer_opened so event bus subscribers
  # (Git.Tracker, FileWatcher, Project, SyncServer, Config.Hooks) react.
  @spec register_buffer(state(), pid(), String.t()) :: state()
  defp register_buffer(state, buffer_pid, file_path) do
    state = Commands.add_buffer(state, buffer_pid)
    state = log_message(state, "Opened: #{file_path}")
    state = BufferLifecycle.lsp_buffer_opened(state, buffer_pid)

    Minga.Events.broadcast(:buffer_opened, %Minga.Events.BufferEvent{
      buffer: buffer_pid,
      path: file_path
    })

    state
  end

  @spec log_message(state(), String.t()) :: state()
  defp log_message(state, text), do: MessageLog.log(state, text)

  # ── GUI action dispatch ────────────────────────────────────────────────
  # Semantic commands from SwiftUI chrome. Each action maps to existing
  # editor operations. These are wired up as SwiftUI views are built;
  # unimplemented actions log a message and return state unchanged.

  @spec handle_gui_action(state(), Protocol.GUI.gui_action()) :: state()
  defp handle_gui_action(state, {:select_tab, id}) do
    EditorState.switch_tab(state, id)
  end

  defp handle_gui_action(state, {:close_tab, _id}) do
    # Close specific tab by id. For now, use force_quit which closes
    # the active tab. Full implementation in a later step.
    Commands.BufferManagement.execute(state, :force_quit)
  end

  defp handle_gui_action(state, {:file_tree_click, index}) do
    gui_tree_action(state, index, :click)
  end

  defp handle_gui_action(state, {:file_tree_toggle, index}) do
    gui_tree_action(state, index, :toggle)
  end

  defp handle_gui_action(state, {:completion_select, index}) do
    case state.completion do
      %Completion{} = comp ->
        updated = %{comp | selected: index}
        do_accept_completion(%{state | completion: updated}, updated)

      nil ->
        state
    end
  end

  defp handle_gui_action(state, {:breadcrumb_click, _segment_index}) do
    # Breadcrumb navigation is a follow-up feature.
    state
  end

  defp handle_gui_action(state, {:toggle_panel, 0}) do
    Commands.FileTree.toggle(state)
  end

  defp handle_gui_action(state, {:toggle_panel, _panel}) do
    # Other panel toggles (diagnostics, etc.) are follow-up features.
    state
  end

  defp handle_gui_action(state, :new_tab) do
    Commands.BufferManagement.execute(state, :new_buffer)
  end

  # Moves the file tree cursor to the given index and performs the action.
  @spec gui_tree_action(state(), non_neg_integer(), :click | :toggle) :: state()
  defp gui_tree_action(%{file_tree: %{tree: nil}} = state, _index, _action), do: state

  defp gui_tree_action(state, index, action) do
    tree = %{state.file_tree.tree | cursor: index}
    state = put_in(state.file_tree.tree, tree)

    case action do
      :click -> Commands.FileTree.open_or_toggle(state)
      :toggle -> Commands.FileTree.open_or_toggle(state)
    end
  end

  # ── Warning popup debounce ───────────────────────────────────────────────

  @warning_popup_debounce_ms 200

  @spec maybe_schedule_warning_popup(state()) :: state()
  defp maybe_schedule_warning_popup(%{warning_popup_timer: ref} = state) when is_reference(ref) do
    # Timer already running; the pending timeout will open the popup.
    state
  end

  defp maybe_schedule_warning_popup(state) do
    ref = Process.send_after(self(), :warning_popup_timeout, @warning_popup_debounce_ms)
    %{state | warning_popup_timer: ref}
  end

  @spec open_warnings_popup_if_needed(state()) :: state()
  defp open_warnings_popup_if_needed(%{warnings_popup_dismissed: true} = state), do: state
  defp open_warnings_popup_if_needed(%{buffers: %{warnings: nil}} = state), do: state

  defp open_warnings_popup_if_needed(state) do
    warnings_buf = state.buffers.warnings

    # Check if *Warnings* is already visible in any window
    already_visible =
      Enum.any?(state.windows.map, fn {_id, win} ->
        win.buffer == warnings_buf
      end)

    if already_visible do
      # Scroll the warnings window to the end so the latest entry is visible
      scroll_warnings_to_end(state, warnings_buf)
    else
      open_warnings_popup(state, warnings_buf)
    end
  end

  @spec open_warnings_popup(state(), pid()) :: state()
  defp open_warnings_popup(state, warnings_buf) do
    case PopupLifecycle.open_popup(state, "*Warnings*", warnings_buf) do
      {:ok, new_state} -> schedule_render(new_state, 16)
      :no_match -> state
    end
  end

  @spec scroll_warnings_to_end(state(), pid()) :: state()
  defp scroll_warnings_to_end(state, warnings_buf) do
    case Enum.find(state.windows.map, fn {_id, win} -> win.buffer == warnings_buf end) do
      {_id, _win} ->
        # Trigger a render so the viewport catches up to the appended content.
        schedule_render(state, 16)

      nil ->
        state
    end
  end

  # Returns true if the given buffer PID is visible in any window.
  @spec buffer_visible_in_window?(state(), pid()) :: boolean()
  defp buffer_visible_in_window?(state, buf_pid) do
    Enum.any?(state.windows.map, fn {_id, win} -> win.buffer == buf_pid end)
  end

  # ── Window resize ────────────────────────────────────────────────────────

  @spec resize_all_windows(state()) :: state()
  defp resize_all_windows(%{windows: %{tree: nil}} = state), do: state

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

  @spec refresh_tree_git_status(state()) :: state()
  defp refresh_tree_git_status(%{file_tree: %{tree: nil}} = state), do: state

  defp refresh_tree_git_status(%{file_tree: %{tree: tree}} = state) do
    updated_tree = Minga.FileTree.refresh_git_status(tree)
    put_in(state.file_tree.tree, updated_tree)
  end

  # ── Public housekeeping API for Input.Router ───────────────────────────────

  @doc false
  @spec do_accept_completion(state(), Completion.t()) :: state()
  defdelegate do_accept_completion(state, completion), to: CompletionHandling, as: :accept

  @doc false
  @spec do_maybe_handle_completion(state(), atom(), non_neg_integer(), non_neg_integer()) ::
          state()
  defdelegate do_maybe_handle_completion(state, old_mode, codepoint, modifiers),
    to: CompletionHandling,
    as: :maybe_handle

  @doc false
  @spec do_render(state()) :: state()
  def do_render(state) do
    Renderer.render(state)
  end

  @doc false
  @spec do_dismiss_completion(state()) :: state()
  defdelegate do_dismiss_completion(state), to: CompletionHandling, as: :dismiss
end
