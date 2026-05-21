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

  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias MingaEditor.Agent.Events
  alias MingaEditor.Agent.UIState
  alias Minga.Buffer
  alias Minga.Clipboard
  alias Minga.Config
  alias Minga.Editing.Completion
  alias Minga.FileRef
  alias Minga.FileWatcher
  alias Minga.Git
  alias Minga.LSP.Supervisor, as: LspSupervisor

  alias Minga.Diagnostics.Decorations, as: DiagDecorations
  alias Minga.Session

  alias MingaEditor.AgentLifecycle
  alias MingaEditor.BottomPanel

  alias MingaEditor.Commands
  alias MingaEditor.CompletionHandling
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.FileWatcherHelpers
  alias MingaEditor.HighlightEvents
  alias MingaEditor.HighlightSync
  alias MingaEditor.KeyDispatch
  alias MingaEditor.Layout
  alias MingaEditor.InlineAsk.Events, as: InlineAskEvents
  alias MingaEditor.LspActions
  alias MingaEditor.MessageLog
  alias MingaEditor.NavFlash
  alias MingaEditor.YankFlash
  alias MingaEditor.Renderer
  alias MingaEditor.SemanticTokenSync
  alias MingaEditor.Startup
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Remote
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.RemoteSession
  alias MingaEditor.Viewport

  alias MingaEditor.Handlers.FileEventHandler
  alias MingaEditor.Handlers.HighlightHandler
  alias MingaEditor.Handlers.SessionHandler
  alias MingaEditor.Handlers.ToolHandler
  # WarningLog removed in #825; warnings route through MessageLog with level override
  alias MingaEditor.Window
  alias MingaEditor.Input
  alias Minga.LSP.SyncServer, as: LspSyncServer
  alias Minga.Mode
  alias Minga.Project.FileTree
  # PopupLifecycle alias removed: warnings popup replaced by bottom panel (#825)
  alias MingaEditor.Frontend.Protocol

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

  alias MingaAgent.Session, as: AgentSession

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.VimState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.Session, as: EditorSessionState

  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Search, as: SearchData
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Tab.Context, as: TabContext

  alias MingaEditor.MinibufferData
  alias MingaEditor.MouseHoverTooltip
  alias MingaEditor.PickerUI

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
       |> EditorState.update_workspace(&SessionState.set_viewport(&1, vp)))
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
      |> EditorState.update_workspace(&SessionState.set_viewport(&1, vp))

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
    new_state = handle_gui_action(state, action)
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

  # Completion debounce timer fired — send the actual completion request
  def handle_info({:completion_debounce, clients, buffer_pid}, state) do
    new_bridge =
      CompletionTrigger.flush_debounce(
        MingaEditor.State.ModalOverlay.completion_trigger(state),
        clients,
        buffer_pid
      )

    {:noreply, MingaEditor.State.ModalOverlay.put_completion_trigger(state, new_bridge)}
  end

  # LSP async response — route to the appropriate handler based on lsp.pending
  def handle_info({:lsp_response, ref, result}, state) do
    case Map.fetch(state.workspace.lsp_pending, ref) do
      {:ok, :completion_resolve} ->
        new_state = delete_lsp_pending(state, ref)
        new_state = CompletionHandling.handle_resolve_response(new_state, result)
        {:noreply, Renderer.render_or_async(new_state)}

      {:ok, :signature_help} ->
        new_state = delete_lsp_pending(state, ref)
        new_state = CompletionHandling.handle_signature_help_response(new_state, result)
        {:noreply, Renderer.render_or_async(new_state)}

      {:ok, {:semantic_tokens, buf_pid}} ->
        new_state = delete_lsp_pending(state, ref)
        new_state = SemanticTokenSync.handle_response(new_state, buf_pid, result)
        {:noreply, Renderer.render_or_async(new_state)}

      {:ok, kind} when is_atom(kind) ->
        new_state = delete_lsp_pending(state, ref)
        new_state = dispatch_lsp_response(kind, new_state, result)
        {:noreply, Renderer.render_or_async(new_state)}

      {:ok, kind} when is_tuple(kind) ->
        new_state = delete_lsp_pending(state, ref)
        new_state = dispatch_lsp_response(kind, new_state, result)
        {:noreply, Renderer.render_or_async(new_state)}

      :error ->
        # Not a tracked request — try completion handler
        handle_lsp_completion_response(ref, result, state)
    end
  end

  # LSP debounce timers (inlay hints and document highlight)
  @lsp_debounce_atoms [:inlay_hint_scroll_debounce, :document_highlight_debounce]

  def handle_info(msg, state) when msg in @lsp_debounce_atoms do
    {:noreply, handle_lsp_debounce(state, msg)}
  end

  # Completion resolve debounce timer fired — send the actual resolve request
  def handle_info({:completion_resolve, index}, state) do
    state = CompletionHandling.flush_resolve(state, index)
    {:noreply, state}
  end

  # Refresh the cached LSP status for the modeline indicator.
  # Fired after buffer open (with delay for async LSP initialization)
  # and periodically while LSP clients are connecting.
  def handle_info(:request_code_lens_and_inlay_hints, state) do
    state = LspActions.code_lens(state)
    state = LspActions.inlay_hints(state)
    {:noreply, state}
  end

  # ── Event bus messages ────────────────────────────────────────────────────────
  # All {:minga_event, event, payload} messages are routed through a single
  # catch-all to the appropriate handler or inline logic. This replaces 10
  # individual thin router clauses (LSP, diagnostics, tool, file events).
  def handle_info({:minga_event, event, payload} = msg, state) do
    {:noreply, dispatch_minga_event(state, event, payload, msg)}
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

    if InlineAskEvents.session?(state, session_pid) do
      state = InlineAskEvents.handle_event(state, session_pid, event)
      {:noreply, schedule_render(state, 16)}
    else
      if AgentAccess.session(state) == session_pid do
        state = dispatch_agent_event(state, event)
        {:noreply, state}
      else
        # Background session: dispatch to shell for presentation updates
        # (tab badges, card status, attention flags, etc.)
        {shell_state, workspace, shell_effects} =
          state.shell.on_agent_event(state.shell_state, state.workspace, session_pid, event)

        state = %{state | shell_state: shell_state, workspace: workspace}
        state = apply_effects(state, shell_effects)
        {:noreply, schedule_render(state, 16)}
      end
    end
  end

  def handle_info({:inline_ask_prompt_sent, session_pid, result}, state) do
    state = InlineAskEvents.handle_prompt_result(state, session_pid, result)
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

  # ── Minga event dispatch ──────────────────────────────────────────────────

  # Routes {:minga_event, event, payload} to the correct handler or inline logic.
  @tool_events [
    :tool_install_started,
    :tool_install_progress,
    :tool_install_complete,
    :tool_install_failed,
    :tool_uninstall_complete,
    :tool_missing
  ]

  @file_events [
    :git_status_changed,
    :buffer_saved,
    :buffer_changed,
    :file_written,
    :project_rebuilt
  ]

  @spec dispatch_minga_event(EditorState.t(), atom(), term(), term()) :: EditorState.t()
  defp dispatch_minga_event(state, event, _payload, msg) when event in @tool_events do
    {state, effects} = ToolHandler.handle(state, msg)
    apply_effects(state, effects)
  end

  defp dispatch_minga_event(state, event, _payload, msg) when event in @file_events do
    {state, effects} = FileEventHandler.handle(state, msg)
    apply_effects(state, effects)
  end

  defp dispatch_minga_event(
         state,
         :lsp_status_changed,
         %Minga.Events.LspStatusEvent{name: name, status: status},
         _msg
       ) do
    old_status = state.lsp.status
    new_lsp = LSPState.update_server_status(state.lsp, name, status)
    state = %{state | lsp: new_lsp}
    if new_lsp.status != old_status, do: schedule_render(state, 16), else: state
  end

  defp dispatch_minga_event(
         state,
         :diagnostics_updated,
         %Minga.Events.DiagnosticsUpdatedEvent{uri: uri},
         msg
       ) do
    apply_diagnostic_decorations(state, uri)
    {state, effects} = FileEventHandler.handle(state, msg)

    if effects == [] do
      schedule_render(state, 16)
    else
      apply_effects(state, effects)
    end
  end

  defp dispatch_minga_event(
         state,
         :log_message,
         %Minga.Events.LogMessageEvent{text: text, level: level},
         _msg
       ) do
    MessageLog.append_to_store(state, text, level)
  end

  defp dispatch_minga_event(
         state,
         :option_changed,
         %Minga.Events.OptionChangedEvent{
           source: source,
           name: :cursor_animate,
           value: enabled
         },
         _msg
       )
       when is_boolean(enabled) do
    if option_source_matches?(source, EditorState.options_server(state)) do
      Startup.send_cursor_animation_config(state, enabled)
    end

    state
  end

  defp dispatch_minga_event(
         state,
         :option_changed,
         %Minga.Events.OptionChangedEvent{source: source, name: name, value: value},
         _msg
       ) do
    if option_source_matches?(source, EditorState.options_server(state)) and
         MingaEditor.Frontend.Protocol.GUI.settings_option?(name) do
      state
      |> apply_runtime_config_option(name, value)
      |> push_config_state_entry(name, value)
    else
      state
    end
  end

  defp dispatch_minga_event(
         state,
         :face_overrides_changed,
         %Minga.Events.FaceOverridesChangedEvent{buffer: buf_pid, overrides: overrides},
         _msg
       ) do
    # Pre-compute the merged face registry so the render pipeline reads from
    # editor state with zero GenServer calls back into the buffer.
    registries =
      if overrides == %{} do
        Map.delete(state.face_override_registries, buf_pid)
      else
        hl = Map.get(state.workspace.highlight.highlights, buf_pid)

        merged =
          if hl do
            MingaEditor.UI.Face.Registry.with_overrides(hl.face_registry, overrides)
          else
            base = MingaEditor.UI.Face.Registry.from_theme(state.theme)
            MingaEditor.UI.Face.Registry.with_overrides(base, overrides)
          end

        Map.put(state.face_override_registries, buf_pid, merged)
      end

    %{state | face_override_registries: registries}
  end

  defp dispatch_minga_event(
         state,
         :node_connected,
         %Minga.Distribution.Events.NodeConnectedEvent{} = event,
         _msg
       ) do
    handle_node_connected(state, event)
  end

  defp dispatch_minga_event(
         state,
         :node_disconnected,
         %Minga.Distribution.Events.NodeDisconnectedEvent{} = event,
         _msg
       ) do
    handle_node_disconnected(state, event)
  end

  defp dispatch_minga_event(
         state,
         :background_subagent_started,
         %MingaAgent.Subagent.Handle{} = handle,
         _msg
       ) do
    MingaAgent.Session.subscribe(handle.pid, self())

    {shell_state, workspace} =
      state.shell.handle_event(
        state.shell_state,
        state.workspace,
        {:background_subagent_started, handle}
      )

    state = %{state | shell_state: shell_state, workspace: workspace}
    schedule_render(state, 16)
  end

  defp dispatch_minga_event(
         state,
         :agent_session_stopped,
         %MingaAgent.SessionManager.SessionStoppedEvent{pid: pid, reason: reason},
         _msg
       ) do
    if reason in [:normal, :shutdown] do
      Minga.Log.info(:agent, "[Agent] Session #{inspect(pid)} stopped")
    else
      Minga.Log.error(
        :agent,
        "[Agent] Session #{inspect(pid)} crashed: #{inspect(reason, pretty: true, limit: 500)}"
      )
    end

    Commands.BufferManagement.handle_agent_session_down(state, pid, reason)
  end

  defp dispatch_minga_event(state, :load_user_themes, _payload, _msg) do
    alias MingaEditor.UI.Theme.Loader, as: ThemeLoader

    {themes, errors} = ThemeLoader.load_all()
    MingaEditor.UI.Theme.register_user_themes(themes)

    for %{path: path, error: error} <- errors do
      Minga.Log.warning(:editor, "Theme load error: #{path}: #{error}")
    end

    state
  end

  defp dispatch_minga_event(
         state,
         :extension_updates_available,
         %Minga.Extension.UpdatesAvailableEvent{updates: updates},
         _msg
       ) do
    alias Minga.Mode.ExtensionConfirmState

    ms = %ExtensionConfirmState{updates: updates}
    EditorState.transition_mode(state, :extension_confirm, ms)
  end

  defp dispatch_minga_event(state, _event, _payload, _msg), do: state

  @spec option_source_matches?(GenServer.server(), GenServer.server()) :: boolean()
  defp option_source_matches?(source, server) when source == server, do: true

  defp option_source_matches?(source, server) when is_atom(source) and is_pid(server),
    do: Process.whereis(source) == server

  defp option_source_matches?(source, server) when is_pid(source) and is_atom(server),
    do: Process.whereis(server) == source

  defp option_source_matches?(_source, _server), do: false

  @spec push_full_config_state(EditorState.t()) :: :ok
  defp push_full_config_state(%{port_manager: nil}), do: :ok

  defp push_full_config_state(%{port_manager: port} = state) do
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

  @spec push_config_state_entry(EditorState.t(), atom(), term()) :: EditorState.t()
  defp push_config_state_entry(%{port_manager: nil} = state, _name, _value), do: state

  defp push_config_state_entry(%{port_manager: port} = state, name, value) do
    if MingaEditor.Frontend.gui?(state.capabilities) and
         MingaEditor.Frontend.Protocol.GUI.settings_option?(name) do
      config_state = MingaEditor.Frontend.Protocol.GUI.config_state_entry(name, value)
      MingaEditor.Frontend.send_config_state(port, config_state)
    end

    state
  catch
    :exit, _ -> state
  end

  @spec apply_runtime_config_option(EditorState.t(), atom(), term()) :: EditorState.t()
  defp apply_runtime_config_option(state, :theme, theme_name) when is_atom(theme_name) do
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

  defp apply_runtime_config_option(state, name, _value)
       when name in [:font_family, :font_size, :font_weight, :font_ligatures] do
    Startup.send_font_config(state)
    state
  end

  defp apply_runtime_config_option(state, name, value)
       when name in [:line_numbers, :wrap, :tab_width] do
    Enum.each(runtime_config_buffers(state), fn buffer ->
      Buffer.set_option(buffer, name, value)
    end)

    state
    |> EditorState.invalidate_all_windows()
    |> Layout.invalidate()
  end

  defp apply_runtime_config_option(state, :cursorline, _value) do
    state
    |> EditorState.invalidate_all_windows()
    |> Layout.invalidate()
  end

  defp apply_runtime_config_option(state, _name, _value), do: state

  @spec runtime_config_buffers(EditorState.t()) :: [pid()]
  defp runtime_config_buffers(state) do
    state.workspace.buffers.list
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  @spec handle_node_connected(EditorState.t(), Minga.Distribution.Events.NodeConnectedEvent.t()) ::
          EditorState.t()
  defp handle_node_connected(state, %{server_name: server_name, node: remote_node}) do
    sessions = discover_remote_sessions(remote_node, server_name)

    state =
      EditorState.update_remote(state, fn remote ->
        remote
        |> Remote.put_sessions(server_name, sessions)
        |> Remote.put_server_status(server_name, :connected)
      end)

    state = reconnect_remote_tabs(state, server_name, remote_node)
    count = length(sessions)
    status = remote_connected_status(server_name, count)
    EditorState.set_status(state, status)
  end

  @spec handle_node_disconnected(
          EditorState.t(),
          Minga.Distribution.Events.NodeDisconnectedEvent.t()
        ) :: EditorState.t()
  defp handle_node_disconnected(state, %{server_name: server_name}) do
    state =
      EditorState.update_remote(state, &Remote.put_server_status(&1, server_name, :disconnected))

    state = mark_remote_tabs(state, server_name, :disconnected)

    if active_remote_server?(state, server_name) do
      state
      |> AgentAccess.update_agent(&AgentState.stop_spinner_timer/1)
      |> AgentAccess.update_agent(
        &AgentState.set_error(&1, "[#{server_name}] disconnected, reconnecting...")
      )
      |> EditorState.set_status("[#{server_name}] disconnected, reconnecting...")
    else
      EditorState.set_status(state, "[#{server_name}] disconnected, reconnecting...")
    end
  end

  @spec discover_remote_sessions(node(), String.t()) :: [Remote.remote_session_entry()]
  defp discover_remote_sessions(remote_node, server_name) do
    :erpc.call(remote_node, MingaAgent.SessionManager, :list_sessions, [], 5_000)
  catch
    :exit, reason ->
      Minga.Log.warning(
        :distribution,
        "Failed to discover sessions on #{server_name}: #{inspect(reason)}"
      )

      []
  end

  @spec remote_connected_status(String.t(), non_neg_integer()) :: String.t()
  defp remote_connected_status(server_name, 0),
    do: "Connected to #{server_name} (no active sessions)"

  defp remote_connected_status(server_name, count),
    do: "Connected to #{server_name} (#{count} active sessions)"

  @spec reconnect_remote_tabs(EditorState.t(), String.t(), node()) :: EditorState.t()
  defp reconnect_remote_tabs(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         server_name,
         remote_node
       ) do
    workspaces = TabBar.remote_workspaces_for_server(tb, server_name)

    Enum.reduce(workspaces, state, fn workspace, acc ->
      reconnect_remote_workspace(acc, workspace, remote_node)
    end)
  end

  defp reconnect_remote_tabs(state, _server_name, _remote_node), do: state

  @spec reconnect_remote_workspace(EditorState.t(), Workspace.t(), node()) :: EditorState.t()
  defp reconnect_remote_workspace(
         state,
         %Workspace{remote_session: %RemoteSession{session_id: session_id}} = workspace,
         remote_node
       ) do
    case remote_session_pid(remote_node, session_id) do
      {:ok, pid} ->
        restore_remote_workspace(state, workspace, pid)

      {:error, :not_found} ->
        restore_remote_session_from_store(state, workspace, remote_node, session_id)

      {:error, _reason} ->
        mark_remote_workspace_status(state, workspace, :disconnected)
    end
  end

  defp reconnect_remote_workspace(state, %Workspace{}, _remote_node), do: state

  @spec remote_session_pid(node(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp remote_session_pid(remote_node, session_id) do
    :erpc.call(remote_node, MingaAgent.SessionManager, :get_session, [session_id], 5_000)
  catch
    :exit, reason -> {:error, {:remote_unavailable, reason}}
  end

  @spec restore_remote_session_from_store(EditorState.t(), Workspace.t(), node(), String.t()) ::
          EditorState.t()
  defp restore_remote_session_from_store(state, workspace, remote_node, session_id) do
    case remote_session_data(remote_node, session_id) do
      {:ok, %{messages: messages}} -> restore_ended_remote_workspace(state, workspace, messages)
      {:error, _reason} -> mark_remote_workspace_status(state, workspace, :unavailable)
    end
  end

  @spec remote_session_data(node(), String.t()) ::
          {:ok, MingaAgent.SessionStore.session_data()} | {:error, term()}
  defp remote_session_data(remote_node, session_id) do
    :erpc.call(remote_node, MingaAgent.SessionStore, :load, [session_id], 5_000)
  catch
    :exit, reason -> {:error, {:remote_unavailable, reason}}
  end

  @spec restore_ended_remote_workspace(EditorState.t(), Workspace.t(), [term()]) ::
          EditorState.t()
  defp restore_ended_remote_workspace(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         %Workspace{id: workspace_id} = workspace,
         messages
       ) do
    tb = set_workspace_remote_state(tb, workspace, nil, :ended)
    state = EditorState.set_tab_bar(state, tb)

    if active_workspace?(tb, workspace_id) do
      case AgentAccess.agent(state).buffer do
        pid when is_pid(pid) -> AgentBufferSync.sync(pid, messages)
        _ -> :ok
      end

      state
      |> AgentAccess.update_agent(&AgentState.set_error(&1, "Remote session ended"))
      |> EditorState.set_status("Remote session ended")
    else
      state
    end
  end

  defp restore_ended_remote_workspace(state, %Workspace{}, _messages), do: state

  @spec restore_remote_workspace(EditorState.t(), Workspace.t(), pid()) :: EditorState.t()
  defp restore_remote_workspace(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         %Workspace{id: workspace_id} = workspace,
         pid
       ) do
    MingaAgent.Session.subscribe(pid, self())

    tb = set_workspace_remote_state(tb, workspace, pid, :connected)
    state = EditorState.set_tab_bar(state, tb)

    if active_workspace?(tb, workspace_id) do
      state
      |> maybe_rebuild_agent_from_workspace(workspace_id)
      |> AgentLifecycle.sync_buffer()
    else
      state
    end
  catch
    :exit, _reason -> mark_remote_workspace_status(state, workspace, :disconnected)
  end

  defp restore_remote_workspace(state, %Workspace{}, _pid), do: state

  @spec mark_remote_tabs(EditorState.t(), String.t(), Tab.connection_status()) :: EditorState.t()
  defp mark_remote_tabs(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, server_name, status) do
    EditorState.set_tab_bar(state, TabBar.set_remote_connection_status(tb, server_name, status))
  end

  defp mark_remote_tabs(state, _server_name, _status), do: state

  @spec mark_remote_workspace_status(
          EditorState.t(),
          Workspace.t(),
          :connected | :disconnected | :unavailable
        ) ::
          EditorState.t()
  defp mark_remote_workspace_status(state, workspace, :unavailable) do
    mark_remote_workspace_without_live_session(state, workspace, :unavailable)
  end

  defp mark_remote_workspace_status(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         %Workspace{} = workspace,
         status
       ) do
    EditorState.set_tab_bar(
      state,
      set_workspace_remote_state(tb, workspace, workspace.session, status)
    )
  end

  defp mark_remote_workspace_status(state, %Workspace{}, _status), do: state

  @spec mark_remote_workspace_without_live_session(
          EditorState.t(),
          Workspace.t(),
          :unavailable
        ) :: EditorState.t()
  defp mark_remote_workspace_without_live_session(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         %Workspace{} = workspace,
         status
       ) do
    EditorState.set_tab_bar(state, set_workspace_remote_state(tb, workspace, nil, status))
  end

  defp mark_remote_workspace_without_live_session(state, %Workspace{}, _status), do: state

  @spec set_workspace_remote_state(
          TabBar.t(),
          Workspace.t(),
          pid() | nil,
          RemoteSession.connection_status()
        ) ::
          TabBar.t()
  defp set_workspace_remote_state(%TabBar{} = tb, %Workspace{id: workspace_id}, session, status) do
    tb
    |> TabBar.update_workspace(workspace_id, fn workspace ->
      workspace
      |> set_workspace_live_session(session)
      |> Workspace.set_remote_connection_status(status)
    end)
    |> TabBar.sync_workspace_agent_tab_projection(workspace_id)
  end

  @spec set_workspace_live_session(Workspace.t(), pid() | nil) :: Workspace.t()
  defp set_workspace_live_session(%Workspace{} = workspace, nil),
    do: Workspace.clear_session(workspace)

  defp set_workspace_live_session(%Workspace{} = workspace, session) when is_pid(session) do
    Workspace.set_session(workspace, session)
  end

  @spec maybe_rebuild_agent_from_workspace(EditorState.t(), non_neg_integer()) :: EditorState.t()
  defp maybe_rebuild_agent_from_workspace(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         workspace_id
       ) do
    case workspace_agent_tab(tb, workspace_id) do
      %Tab{} = tab -> EditorState.rebuild_agent_from_session(state, tab)
      nil -> state
    end
  end

  defp maybe_rebuild_agent_from_workspace(state, _workspace_id), do: state

  @spec workspace_agent_tab(TabBar.t(), non_neg_integer()) :: Tab.t() | nil
  defp workspace_agent_tab(%TabBar{} = tb, workspace_id) do
    tb
    |> TabBar.tabs_in_workspace(workspace_id)
    |> Enum.find(&(&1.kind == :agent))
  end

  @spec active_workspace?(TabBar.t(), non_neg_integer()) :: boolean()
  defp active_workspace?(%TabBar{} = tb, workspace_id),
    do: TabBar.active_workspace_id(tb) == workspace_id

  @spec active_remote_server?(EditorState.t(), String.t()) :: boolean()
  defp active_remote_server?(%{shell_state: %{tab_bar: %TabBar{} = tb}}, server_name) do
    case TabBar.active_workspace(tb) do
      %Workspace{} = workspace -> Workspace.remote_server?(workspace, server_name)
      _workspace -> false
    end
  end

  defp active_remote_server?(state, server_name) do
    case state.shell.active_tab(state.shell_state) do
      %Tab{server_name: ^server_name} -> true
      _ -> false
    end
  end

  # ── LSP response dispatch ──────────────────────────────────────────────────

  @spec set_lsp_pending(state(), %{reference() => atom() | tuple()}) :: state()
  defp set_lsp_pending(state, pending) do
    EditorState.update_workspace(state, &SessionState.set_lsp_pending(&1, pending))
  end

  @spec delete_lsp_pending(state(), reference()) :: state()
  defp delete_lsp_pending(state, ref) do
    set_lsp_pending(state, Map.delete(state.workspace.lsp_pending, ref))
  end

  # Dispatches an LSP response to the appropriate handler based on the kind atom.
  @spec dispatch_lsp_response(term(), EditorState.t(), term()) :: EditorState.t()
  defp dispatch_lsp_response(:definition, state, result),
    do: LspActions.handle_definition_response(state, result)

  defp dispatch_lsp_response(:peek_definition, state, result),
    do: LspActions.handle_peek_definition_response(state, result)

  defp dispatch_lsp_response(:hover, state, result),
    do: LspActions.handle_hover_response(state, result)

  defp dispatch_lsp_response({:hover_mouse, row, col}, state, result),
    do: LspActions.handle_hover_mouse_response(state, result, row, col)

  defp dispatch_lsp_response(:references, state, result),
    do: LspActions.handle_references_response(state, result)

  defp dispatch_lsp_response(:document_highlight, state, result),
    do: LspActions.handle_document_highlight_response(state, result)

  defp dispatch_lsp_response(:code_action, state, result),
    do: LspActions.handle_code_action_response(state, result)

  defp dispatch_lsp_response(:prepare_rename, state, result),
    do: LspActions.handle_prepare_rename_response(state, result)

  defp dispatch_lsp_response(:rename, state, result),
    do: LspActions.handle_rename_response(state, result)

  defp dispatch_lsp_response(:type_definition, state, result),
    do: LspActions.handle_type_definition_response(state, result)

  defp dispatch_lsp_response(:implementation, state, result),
    do: LspActions.handle_implementation_response(state, result)

  defp dispatch_lsp_response(:document_symbol, state, result),
    do: LspActions.handle_document_symbol_response(state, result)

  defp dispatch_lsp_response(:workspace_symbol, state, result),
    do: LspActions.handle_workspace_symbol_response(state, result)

  defp dispatch_lsp_response(:selection_range, state, result),
    do: LspActions.handle_selection_range_response(state, result)

  defp dispatch_lsp_response(:prepare_call_hierarchy, state, result),
    do: LspActions.handle_prepare_call_hierarchy_response(state, result)

  defp dispatch_lsp_response(:incoming_calls, state, result),
    do: LspActions.handle_incoming_calls_response(state, result)

  defp dispatch_lsp_response(:outgoing_calls, state, result),
    do: LspActions.handle_outgoing_calls_response(state, result)

  defp dispatch_lsp_response(:prepare_outgoing_hierarchy, state, result),
    do: LspActions.handle_prepare_outgoing_hierarchy_response(state, result)

  defp dispatch_lsp_response(:code_lens, state, result),
    do: LspActions.handle_code_lens_response(state, result)

  defp dispatch_lsp_response(:code_lens_resolve, state, result),
    do: LspActions.handle_code_lens_resolve_response(state, result)

  defp dispatch_lsp_response(:inlay_hint, state, result),
    do: LspActions.handle_inlay_hint_response(state, result)

  defp dispatch_lsp_response(kind, state, _result) do
    Minga.Log.debug(:lsp, "Unhandled LSP response kind: #{inspect(kind)}")
    state
  end

  # ── Agent event dispatch ──────────────────────────────────────────────────

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
  * `{:save_session_deferred}` — send :save_session to self
  * `{:schedule_file_tree_refresh, delay}` — debounce one filesystem tree refresh
  * `{:handle_git_remote_result, ref, result}` — process git remote result
  """
  @type effect ::
          :render
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

  @spec handle_lsp_debounce(state(), atom()) :: state()
  defp handle_lsp_debounce(state, :inlay_hint_scroll_debounce) do
    state = %{state | lsp: LSPState.clear_inlay_hint_timer(state.lsp)}
    LspActions.inlay_hints(state)
  end

  defp handle_lsp_debounce(state, :document_highlight_debounce) do
    state = %{state | lsp: LSPState.clear_highlight_timer(state.lsp)}
    LspActions.document_highlight(state)
  end

  @spec handle_lsp_completion_response(reference(), term(), state()) :: {:noreply, state()}
  defp handle_lsp_completion_response(ref, result, state) do
    new_state = CompletionHandling.handle_response(state, ref, result)
    new_state = Renderer.render_or_async(new_state)
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
  # apply_textobject_positions moved to HighlightHandler

  @spec schedule_render(state(), non_neg_integer()) :: state()
  defp schedule_render(%{render_timer: ref} = state, _delay_ms) when is_reference(ref), do: state

  # In test mode (headless backend), render synchronously to eliminate timer
  # races that cause CI flakiness. No debounce needed when there's no real
  # display to coalesce frames for.
  defp schedule_render(%{backend: :headless} = state, _delay_ms) do
    state = maybe_trigger_nav_flash(state)
    state = Renderer.render_or_async(state)
    %{state | render_timer: nil}
  end

  defp schedule_render(state, delay_ms) do
    ref = Process.send_after(self(), :debounced_render, delay_ms)
    %{state | render_timer: ref}
  end

  # LSP status aggregation moved to MingaEditor.State.LSP

  # ── Diagnostic decorations ──────────────────────────────────────────────────

  # Applies diagnostic underline decorations to the buffer matching the URI.
  # Called when {:minga_event, :diagnostics_updated, ...} arrives via the event bus.
  @spec apply_diagnostic_decorations(state(), String.t()) :: :ok
  defp apply_diagnostic_decorations(state, uri) do
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

    EditorState.update_workspace(new_state, fn ws ->
      SessionState.set_file_tree(
        ws,
        FileTreeState.set_tree(ws.file_tree, FileTree.reveal(tree, path))
      )
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

  # Like register_buffer but adds the buffer in the background without
  # switching the active window. Used by ensure_buffer_for_path so agent
  # edits don't yank the user away from their current file.
  # Skips code_lens/inlay_hint scheduling; those are lazy-loaded when
  # the user explicitly opens the buffer.
  @spec register_buffer_background(state(), pid(), String.t()) :: state()
  defp register_buffer_background(state, buffer_pid, file_path) do
    state =
      EditorState.update_workspace(state, fn ws ->
        SessionState.set_buffers(ws, Buffers.add_background(ws.buffers, buffer_pid))
      end)

    state = EditorState.monitor_buffer(state, buffer_pid)
    log_message(state, "Opened (agent): #{file_path}")
  end

  @spec log_message(state(), String.t()) :: state()
  defp log_message(state, text), do: MessageLog.log(state, text)

  # ── GUI action dispatch ────────────────────────────────────────────────
  # Semantic commands from SwiftUI chrome. Each action maps to existing
  # editor operations. These are wired up as SwiftUI views are built;
  # unimplemented actions log a message and return state unchanged.

  @spec handle_gui_action(state(), Protocol.GUI.gui_action()) :: state()

  # Route gui_actions through the active Shell first. Shells that handle
  # the action return updated state; unhandled actions fall through to
  # the Traditional-specific handlers below.
  defp handle_gui_action(state, :system_will_sleep) do
    Minga.Log.info(:editor, "System will sleep")
    state
  end

  defp handle_gui_action(state, :system_did_wake) do
    Minga.Log.info(:editor, "System did wake; refreshing files, LSP, and git")
    FileWatcher.check_all()
    refresh_current_git_repo()
    LspSupervisor.restart_all_clients()
    LspSyncServer.resync_buffers(buffers_for_lsp_resync(state))

    state
    |> EditorState.invalidate_all_windows()
    |> Layout.invalidate()
    |> Renderer.render_or_async()
  end

  defp handle_gui_action(state, :config_query) do
    push_full_config_state(state)
    state
  end

  defp handle_gui_action(state, {:config_update, name, value}) do
    if MingaEditor.Frontend.Protocol.GUI.settings_option?(name) do
      case Minga.Config.Options.set(EditorState.options_server(state), name, value) do
        {:ok, persisted_value} ->
          Minga.Config.Options.mark_explicit(EditorState.options_server(state), name)
          Minga.Config.Writer.persist(name, persisted_value)

          state
          |> apply_runtime_config_option(name, persisted_value)
          |> push_config_state_entry(name, persisted_value)

        {:error, reason} ->
          Minga.Log.warning(:config, "Ignored GUI config update for #{inspect(name)}: #{reason}")
          state
      end
    else
      Minga.Log.warning(
        :config,
        "Ignored GUI config update outside settings panel for #{inspect(name)}"
      )

      state
    end
  end

  defp handle_gui_action(%{shell: MingaEditor.Shell.Board} = state, action) do
    {shell_state, workspace} =
      MingaEditor.Shell.Board.handle_gui_action(state.shell_state, state.workspace, action)

    state = %{state | shell_state: shell_state, workspace: workspace}

    # After Board zoom into an agent card, atomically activate the
    # agent view (session, scope, window content, prompt focus).
    # The Board handler can't do this because it only has
    # (shell_state, workspace), not the full EditorState.
    case action do
      {:board_select_card, card_id} ->
        card = Map.get(shell_state.cards, card_id)

        {new_board, state} =
          MingaEditor.Shell.Board.SessionLifecycle.ensure_session(state.shell_state, card, state)

        state = EditorState.update_shell_state(state, fn _ -> new_board end)
        card = new_board.cards[card_id]
        MingaEditor.AgentActivation.activate_for_card(state, card)

      _ ->
        state
    end
  end

  defp handle_gui_action(state, {:select_tab, id}) do
    EditorState.switch_tab(state, id)
  end

  defp handle_gui_action(state, {:tab_copy_path, id}) do
    copy_tab_path(state, id)
  end

  defp handle_gui_action(state, :hover_open_action) do
    accept_hover_open_action(state)
  end

  defp handle_gui_action(state, {:close_tab, id}) do
    # Delegate to the shell: Traditional switches to the target tab when
    # needed; Board and tab-bar-less Traditional return unchanged.
    {shell_state, workspace} =
      state.shell.handle_gui_action(state.shell_state, state.workspace, {:close_tab, id})

    state = %{state | shell_state: shell_state, workspace: workspace}

    # Only close the buffer when the shell has a tab bar.
    # EditorState.active_tab/1 returns nil when there are no tabs.
    if EditorState.active_tab(state) do
      Commands.BufferManagement.execute(state, :force_quit)
    else
      state
    end
  end

  defp handle_gui_action(state, {:file_tree_click, index}) do
    gui_tree_action(state, index, :click)
  end

  defp handle_gui_action(state, {:file_tree_toggle, index}) do
    gui_tree_action(state, index, :toggle)
  end

  defp handle_gui_action(state, {:file_tree_open_in_split, index}) do
    open_file_tree_entry_in_split(state, index)
  end

  defp handle_gui_action(state, {:file_tree_new_file, index}) do
    state = move_tree_cursor(state, index)
    Commands.FileTree.new_file(state)
  end

  defp handle_gui_action(state, {:file_tree_new_folder, index}) do
    state = move_tree_cursor(state, index)
    Commands.FileTree.new_folder(state)
  end

  defp handle_gui_action(state, {:file_tree_edit_confirm, text}) do
    case state.workspace.file_tree.editing do
      nil ->
        state

      %{} ->
        ft = FileTreeState.update_editing_text(state.workspace.file_tree, text)

        state =
          EditorState.update_workspace(state, &SessionState.set_file_tree(&1, ft))

        Commands.FileTree.confirm_editing(state)
    end
  end

  defp handle_gui_action(state, :file_tree_edit_cancel) do
    Commands.FileTree.cancel_editing(state)
  end

  defp handle_gui_action(state, {:file_tree_delete, index}) do
    state = move_tree_cursor(state, index)
    Commands.FileTree.delete(state)
  end

  defp handle_gui_action(state, {:file_tree_rename, index}) do
    state = move_tree_cursor(state, index)
    Commands.FileTree.rename(state)
  end

  defp handle_gui_action(state, {:file_tree_duplicate, index}) do
    state = move_tree_cursor(state, index)
    Commands.FileTree.duplicate(state)
  end

  defp handle_gui_action(state, {:file_tree_move, source_index, target_dir_index}) do
    Commands.FileTree.move(state, source_index, target_dir_index)
  end

  defp handle_gui_action(state, {:file_tree_drop, intent}) do
    Commands.FileTree.drop(state, intent)
  end

  defp handle_gui_action(state, :file_tree_collapse_all) do
    Commands.FileTree.collapse_all(state)
  end

  defp handle_gui_action(state, :file_tree_refresh) do
    Commands.FileTree.refresh(state)
  end

  defp handle_gui_action(state, {:completion_select, index}) do
    case MingaEditor.State.ModalOverlay.completion(state) do
      %Completion{} = comp ->
        accept_visible_completion(state, comp, index)

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

  defp handle_gui_action(state, {:toggle_panel, 1}) do
    EditorState.set_bottom_panel(state, BottomPanel.toggle(EditorState.bottom_panel(state)))
  end

  defp handle_gui_action(state, {:toggle_panel, 2}) do
    Commands.Git.execute(state, :git_status_toggle)
  end

  defp handle_gui_action(state, {:toggle_panel, 3}) do
    Commands.Agent.toggle_agent_split(state)
  end

  defp handle_gui_action(state, {:toggle_panel, _panel}) do
    state
  end

  defp handle_gui_action(state, :new_tab) do
    Commands.BufferManagement.execute(state, :new_buffer)
  end

  defp handle_gui_action(state, {:panel_switch_tab, tab_index}) do
    EditorState.set_bottom_panel(
      state,
      BottomPanel.switch_tab(EditorState.bottom_panel(state), tab_index)
    )
  end

  defp handle_gui_action(state, :panel_dismiss) do
    EditorState.set_bottom_panel(state, BottomPanel.dismiss(EditorState.bottom_panel(state)))
  end

  defp handle_gui_action(state, {:panel_resize, height_percent}) do
    EditorState.set_bottom_panel(
      state,
      BottomPanel.resize(EditorState.bottom_panel(state), height_percent)
    )
  end

  defp handle_gui_action(state, {:open_file, path}) do
    if File.dir?(path) do
      open_dropped_directory(state, path)
    else
      open_file_by_path(state, path)
    end
  end

  defp handle_gui_action(state, {:tool_install, name_str}) do
    name = String.to_existing_atom(name_str)

    case Minga.Tool.Manager.install(name) do
      :ok -> EditorState.set_status(state, "Installing #{name_str}...")
      {:error, reason} -> EditorState.set_status(state, "Cannot install #{name_str}: #{reason}")
    end
  rescue
    ArgumentError -> EditorState.set_status(state, "Unknown tool: #{name_str}")
  end

  defp handle_gui_action(state, {:tool_uninstall, name_str}) do
    name = String.to_existing_atom(name_str)

    case Minga.Tool.Manager.uninstall(name) do
      :ok -> EditorState.set_status(state, "Uninstalled #{name_str}")
      {:error, reason} -> EditorState.set_status(state, "Cannot uninstall #{name_str}: #{reason}")
    end
  rescue
    ArgumentError -> EditorState.set_status(state, "Unknown tool: #{name_str}")
  end

  defp handle_gui_action(state, {:tool_update, name_str}) do
    name = String.to_existing_atom(name_str)

    case Minga.Tool.Manager.update(name) do
      :ok -> EditorState.set_status(state, "Updating #{name_str}...")
      {:error, reason} -> EditorState.set_status(state, "Cannot update #{name_str}: #{reason}")
    end
  rescue
    ArgumentError -> EditorState.set_status(state, "Unknown tool: #{name_str}")
  end

  defp handle_gui_action(state, :tool_dismiss) do
    # The tool manager panel is closed; no state change needed since
    # visibility is driven by the BEAM's render cycle
    state
  end

  defp handle_gui_action(state, {:agent_tool_toggle, message_index}) do
    session = AgentAccess.session(state)

    if session do
      try do
        AgentSession.toggle_tool_collapse(session, message_index)
      catch
        :exit, _ -> :ok
      end
    end

    state
  end

  defp handle_gui_action(state, {:minibuffer_select, index}) do
    case state.workspace.editing do
      %{mode: :command, mode_state: ms} ->
        {candidates, _total} = MinibufferData.complete_ex_command(ms.input)
        clamped = MinibufferData.clamp_index(index, length(candidates))

        case Enum.at(candidates, clamped) do
          nil ->
            state

          %{label: label} ->
            new_ms = %{ms | input: label, candidate_index: 0}
            set_vim_mode_state(state, new_ms)
        end

      _ ->
        state
    end
  end

  defp handle_gui_action(state, {:execute_command, name_str}) do
    command = String.to_existing_atom(name_str)

    # Discard any follow-up action (dot_repeat, replay_macro): GUI chrome
    # buttons are not vim editing operations and don't participate in the
    # action pipeline.
    case Commands.execute(state, command) do
      {new_state, _action} -> new_state
      new_state -> new_state
    end
  rescue
    ArgumentError ->
      Minga.Log.warning(:editor, "[execute_command] unrecognized command: #{name_str}")
      state
  end

  defp handle_gui_action(state, {:git_stage_file, path}) do
    git_action(
      state,
      fn git_root -> Minga.Git.stage(git_root, git_relative_path(git_root, path)) end,
      "Staged #{path}"
    )
  end

  defp handle_gui_action(state, {:git_unstage_file, path}) do
    git_action(
      state,
      fn git_root -> Minga.Git.unstage(git_root, git_relative_path(git_root, path)) end,
      "Unstaged #{path}"
    )
  end

  defp handle_gui_action(state, {:git_discard_file, path}) do
    git_action(
      state,
      fn git_root -> Minga.Git.discard(git_root, git_relative_path(git_root, path)) end,
      "Discarded #{path}"
    )
  end

  defp handle_gui_action(state, :git_stage_all) do
    git_action(state, fn git_root -> Minga.Git.stage(git_root, ".") end, "Staged all changes")
  end

  defp handle_gui_action(state, :git_unstage_all) do
    git_action(state, fn git_root -> Minga.Git.unstage_all(git_root) end, "Unstaged all")
  end

  defp handle_gui_action(state, {:git_commit, message}) do
    commit_from_gui(state, message, false)
  end

  defp handle_gui_action(state, {:git_commit, message, amend?}) do
    commit_from_gui(state, message, amend?)
  end

  defp handle_gui_action(state, :git_push) do
    Commands.Git.execute(state, :git_push)
  end

  defp handle_gui_action(state, :git_pull) do
    Commands.Git.execute(state, :git_pull)
  end

  defp handle_gui_action(state, :git_fetch) do
    Commands.Git.execute(state, :git_fetch)
  end

  defp handle_gui_action(state, {:git_commit_amend, message}) do
    commit_from_gui(state, message, true)
  end

  defp handle_gui_action(state, {:workspace_close, _ws_id} = action) do
    {shell_state, workspace} =
      state.shell.handle_gui_action(state.shell_state, state.workspace, action)

    state
    |> EditorState.update_shell_state(fn _shell_state -> shell_state end)
    |> EditorState.update_workspace(fn _workspace -> workspace end)
    |> EditorState.sync_agent_ui_from_active_workspace()
  end

  defp handle_gui_action(state, {:workspace_rename, _ws_id, _name} = action) do
    {shell_state, workspace} =
      state.shell.handle_gui_action(state.shell_state, state.workspace, action)

    %{state | shell_state: shell_state, workspace: workspace}
  end

  defp handle_gui_action(state, {:workspace_set_icon, _ws_id, _icon} = action) do
    {shell_state, workspace} =
      state.shell.handle_gui_action(state.shell_state, state.workspace, action)

    %{state | shell_state: shell_state, workspace: workspace}
  end

  defp handle_gui_action(state, {:space_leader_chord, codepoint, modifiers}) do
    MingaEditor.Input.CUA.SpaceLeader.handle_chord(state, codepoint, modifiers)
  end

  defp handle_gui_action(state, {:space_leader_retract, codepoint, modifiers}) do
    MingaEditor.Input.CUA.SpaceLeader.handle_retract(state, codepoint, modifiers)
  end

  defp handle_gui_action(
         %{workspace: %{buffers: %{active: buf}}} = state,
         {:find_pasteboard_search, text, direction}
       )
       when is_pid(buf) do
    # Set the search pattern and execute search_next/search_prev
    state =
      EditorState.update_workspace(state, fn ws ->
        SessionState.set_search(ws, SearchData.record(ws.search, text, :forward))
      end)

    cmd = if direction == 1, do: :search_prev, else: :search_next
    MingaEditor.Commands.execute(state, cmd)
  end

  defp handle_gui_action(state, {:scroll_to_line, line}) do
    # Scroll the active window's viewport to the target line.
    active_win_id = state.workspace.windows.active
    win_map = state.workspace.windows.map

    case Map.get(win_map, active_win_id) do
      nil ->
        state

      window ->
        vp = window.viewport
        new_vp = Viewport.put_top(vp, max(line, 0))
        new_win = MingaEditor.Window.set_viewport(window, new_vp)
        new_map = Map.put(win_map, active_win_id, new_win)

        new_state =
          EditorState.update_workspace(state, fn ws ->
            SessionState.set_windows(ws, Windows.set_map(ws.windows, new_map))
          end)

        Renderer.render_or_async(new_state)
    end
  end

  defp handle_gui_action(state, {:fold_toggle_at_line, window_id, line}) do
    Commands.Folding.execute_at_line(state, window_id, line)
  end

  defp handle_gui_action(state, :cmd_copy) do
    Commands.Editing.execute(state, :cmd_copy)
  end

  defp handle_gui_action(state, :cmd_cut) do
    Commands.Editing.execute(state, :cmd_cut)
  end

  defp handle_gui_action(state, {:git_open_file, path}) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        abs_path = Path.join(git_root, path)
        open_file_by_path(state, abs_path)
    end
  end

  defp handle_gui_action(state, {:git_open_diff, path, section}) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        open_git_diff_from_panel(state, git_root, path, section)
    end
  end

  defp handle_gui_action(state, :git_pull_and_retry) do
    state
    |> EditorState.clear_git_toast()
    |> Commands.Git.execute(:git_pull_and_retry)
  end

  @spec commit_from_gui(state(), String.t(), boolean()) :: state()
  defp commit_from_gui(state, message, amend?) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        opts = if amend?, do: [amend: true], else: []
        result = Minga.Git.commit(git_root, message, opts)
        refresh_git_repo(git_root)
        commit_status(state, result, amend?)
    end
  end

  @spec commit_status(state(), {:ok, String.t()} | {:error, String.t()}, boolean()) :: state()
  defp commit_status(state, {:ok, hash}, true),
    do: EditorState.set_status(state, "Amended #{hash}")

  defp commit_status(state, {:ok, hash}, false),
    do: EditorState.set_status(state, "Committed #{hash}")

  defp commit_status(state, {:error, reason}, true),
    do: EditorState.set_status(state, "Amend failed: #{reason}")

  defp commit_status(state, {:error, reason}, false),
    do: EditorState.set_status(state, "Commit failed: #{reason}")

  @spec open_git_diff_from_panel(state(), String.t(), String.t(), non_neg_integer()) :: state()
  defp open_git_diff_from_panel(state, git_root, path, section) do
    entries = git_status_panel_entries(state)

    matches =
      case section do
        section when section in 0..3 ->
          Enum.filter(entries, &git_status_entry_matches?(&1, path, section))

        _legacy ->
          Enum.filter(entries, &(&1.path == path))
      end

    case matches do
      [%Git.StatusEntry{} = entry] ->
        open_git_diff_for_entry(state, git_root, entry)

      [] ->
        EditorState.set_status(state, "No git diff entry for #{path}")

      [_ | [_ | _]] ->
        EditorState.set_status(
          state,
          "Ambiguous git diff entry for #{path}; use section-aware diff"
        )
    end
  end

  @spec git_status_entry_matches?(Git.StatusEntry.t(), String.t(), non_neg_integer()) :: boolean()
  defp git_status_entry_matches?(%Git.StatusEntry{} = entry, path, section) do
    entry.path == path && git_status_section(entry) == section
  end

  @spec git_status_section(Git.StatusEntry.t()) :: non_neg_integer()
  defp git_status_section(%Git.StatusEntry{staged: true}), do: 0
  defp git_status_section(%Git.StatusEntry{status: :untracked}), do: 2
  defp git_status_section(%Git.StatusEntry{status: :conflict}), do: 3
  defp git_status_section(%Git.StatusEntry{}), do: 1

  @spec git_status_panel_entries(state()) :: [Git.StatusEntry.t()]
  defp git_status_panel_entries(state) do
    case EditorState.git_status_panel(state) do
      nil -> []
      panel -> Map.get(panel, :entries) || []
    end
  end

  @spec open_git_diff_for_entry(state(), String.t(), Git.StatusEntry.t()) :: state()
  defp open_git_diff_for_entry(state, git_root, %Git.StatusEntry{} = entry) do
    abs_path = git_status_abs_path(git_root, entry.path)
    git_path = Path.relative_to(abs_path, git_root)
    git_entry = %{entry | path: git_path}

    case git_diff_content(git_root, abs_path, git_entry) do
      {:ok, current_content} ->
        Commands.Git.open_diff_for_path(state, git_root, git_path, abs_path, current_content,
          staged: entry.staged
        )

      {:error, message} ->
        EditorState.set_status(state, message)
    end
  end

  @spec git_diff_content(String.t(), String.t(), Git.StatusEntry.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp git_diff_content(_git_root, _abs_path, %Git.StatusEntry{status: :deleted}) do
    {:ok, ""}
  end

  defp git_diff_content(git_root, _abs_path, %Git.StatusEntry{path: rel_path, staged: true}) do
    case Git.show_staged(git_root, rel_path) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, "Could not read staged file: #{rel_path}"}
    end
  end

  defp git_diff_content(_git_root, abs_path, %Git.StatusEntry{}) do
    case File.read(abs_path) do
      {:ok, current_content} -> {:ok, current_content}
      {:error, reason} -> {:error, "Could not read file: #{inspect(reason)}"}
    end
  end

  @spec git_relative_path(String.t(), String.t()) :: String.t()
  defp git_relative_path(git_root, path) do
    git_root
    |> git_status_abs_path(path)
    |> Path.relative_to(git_root)
  end

  @spec git_status_abs_path(String.t(), String.t()) :: String.t()
  defp git_status_abs_path(git_root, path) do
    project_root = Minga.Project.resolve_root()

    if String.starts_with?(Path.expand(project_root), Path.expand(git_root)) do
      Path.join(project_root, path)
    else
      Path.join(git_root, path)
    end
  end

  @spec accept_visible_completion(state(), Completion.t(), non_neg_integer()) :: state()
  defp accept_visible_completion(state, comp, index) do
    {visible, _selected_offset} = Completion.visible_items(comp)

    case Enum.at(visible, index) do
      nil ->
        state

      _item ->
        updated = Completion.select_visible(comp, index)

        do_accept_completion(
          MingaEditor.State.ModalOverlay.update_completion(state, fn _ -> updated end),
          updated
        )
    end
  end

  # Project.switch/1 is a cast; the picker opens against current state while the
  # file cache rebuilds asynchronously. BEAM message ordering from the Editor
  # process guarantees the cast reaches Project before any subsequent call.
  @spec open_dropped_directory(state(), String.t()) :: state()
  defp open_dropped_directory(state, dir_path) do
    Minga.Project.switch(dir_path)
    PickerUI.open(state, MingaEditor.UI.Picker.FileSource)
  end

  # Moves the tree cursor to a specific index (used by GUI context menu / header actions).
  @spec move_tree_cursor(state(), non_neg_integer()) :: state()
  defp move_tree_cursor(%{workspace: %{file_tree: %{tree: nil}}} = state, _index), do: state

  defp move_tree_cursor(state, index) do
    EditorState.update_workspace(state, fn ws ->
      tree = FileTree.select(ws.file_tree.tree, index)
      SessionState.set_file_tree(ws, FileTreeState.set_tree(ws.file_tree, tree))
    end)
  end

  @spec git_action(state(), (String.t() -> :ok | {:error, String.t()}), String.t()) :: state()
  defp git_action(state, operation, success_msg) when is_binary(success_msg) do
    git_root = resolve_git_root()

    if git_root do
      case operation.(git_root) do
        :ok ->
          refresh_git_repo(git_root)
          EditorState.set_status(state, success_msg)

        {:error, reason} ->
          EditorState.set_status(state, "Git error: #{reason}")
      end
    else
      EditorState.set_status(state, "Not in a git repository")
    end
  end

  @spec open_file_by_path(state(), String.t()) :: state()
  defp open_file_by_path(state, abs_path) do
    case open_file_by_path_result(state, abs_path) do
      {:ok, new_state} -> new_state
      {:error, _reason} -> EditorState.set_status(state, "Could not open #{abs_path}")
    end
  end

  @spec open_file_by_path_result(state(), String.t()) :: {:ok, state()} | {:error, term()}
  defp open_file_by_path_result(state, abs_path) do
    case file_tab_for_path_in_active_workspace(state, abs_path) do
      %Tab{id: id} -> {:ok, EditorState.switch_tab(state, id)}
      nil -> start_and_register_file(state, abs_path)
    end
  end

  @spec start_and_register_file(state(), String.t()) :: {:ok, state()} | {:error, term()}
  defp start_and_register_file(state, abs_path) do
    case Commands.start_buffer(abs_path, EditorState.options_server(state)) do
      {:ok, pid} ->
        new_state = register_buffer(state, pid, abs_path)
        {:ok, AgentLifecycle.maybe_set_auto_context(new_state, abs_path, pid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec open_file_by_path_in_active_window(state(), String.t()) :: state()
  defp open_file_by_path_in_active_window(state, abs_path) do
    case file_tab_for_path_in_active_workspace(state, abs_path) do
      %Tab{} = tab ->
        open_tab_buffer_in_active_window(state, tab, abs_path)

      nil ->
        case Commands.start_buffer(abs_path, EditorState.options_server(state)) do
          {:ok, pid} -> register_buffer_in_active_window(state, pid, abs_path)
          {:error, _reason} -> EditorState.set_status(state, "Could not open #{abs_path}")
        end
    end
  end

  @spec open_tab_buffer_in_active_window(state(), Tab.t(), String.t()) :: state()
  defp open_tab_buffer_in_active_window(state, tab, abs_path) do
    case tab_active_buffer(tab) do
      pid when is_pid(pid) -> show_buffer_in_active_window(state, pid)
      nil -> EditorState.set_status(state, "Could not open #{abs_path}")
    end
  end

  @spec show_buffer_in_active_window(state(), pid()) :: state()
  defp show_buffer_in_active_window(state, pid) when is_pid(pid) do
    EditorState.update_workspace(state, fn workspace ->
      buffers =
        case Enum.find_index(workspace.buffers.list, &(&1 == pid)) do
          nil -> Buffers.add(workspace.buffers, pid)
          idx -> Buffers.switch_to(workspace.buffers, idx)
        end

      workspace
      |> SessionState.set_buffers(buffers)
      |> SessionState.sync_active_window_buffer()
    end)
  end

  @spec tab_active_buffer(Tab.t()) :: pid() | nil
  defp tab_active_buffer(%Tab{context: context}) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: pid}} when is_pid(pid) -> pid
      _ -> nil
    end
  end

  @spec file_tab_for_path_in_active_workspace(state(), String.t()) :: Tab.t() | nil
  defp file_tab_for_path_in_active_workspace(
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

  defp file_tab_for_path_in_active_workspace(_state, _path), do: nil

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

  @spec register_buffer_in_active_window(state(), pid(), String.t()) :: state()
  defp register_buffer_in_active_window(state, buffer_pid, file_path) do
    state =
      state
      |> EditorState.update_workspace(fn workspace ->
        workspace
        |> SessionState.set_buffers(Buffers.add(workspace.buffers, buffer_pid))
        |> SessionState.sync_active_window_buffer()
      end)
      |> EditorState.monitor_buffer(buffer_pid)

    state = log_message(state, "Opened: #{file_path}")

    Minga.Events.broadcast(
      :buffer_opened,
      %Minga.Events.BufferEvent{buffer: buffer_pid, path: file_path},
      EditorState.events_registry(state)
    )

    state = HighlightSync.setup_for_buffer_pid(state, buffer_pid)

    if state.backend != :headless do
      Process.send_after(self(), :request_code_lens_and_inlay_hints, 800)
    end

    state
  end

  @spec resolve_git_root() :: String.t() | nil
  defp resolve_git_root do
    root = Minga.Project.resolve_root()

    case Minga.Git.root_for(root) do
      {:ok, git_root} -> git_root
      :not_git -> nil
    end
  end

  @spec refresh_current_git_repo() :: :ok
  defp refresh_current_git_repo do
    case resolve_git_root() do
      nil -> :ok
      git_root -> refresh_git_repo(git_root)
    end
  end

  @spec accept_hover_open_action(state()) :: state()
  defp accept_hover_open_action(state) do
    case EditorState.hover_popup(state) do
      %MingaEditor.HoverPopup{open_action: action} when action != nil ->
        state = EditorState.dismiss_hover_popup(state)
        execute_hover_open_action(state, action)

      _ ->
        state
    end
  end

  @spec execute_hover_open_action(state(), MingaEditor.HoverPopup.open_action()) :: state()
  defp execute_hover_open_action(state, {:goto_location, uri, line, col}) do
    LspActions.open_location(state, uri, line, col)
  end

  defp execute_hover_open_action(state, action) when is_atom(action) do
    case Commands.execute(state, action) do
      {new_state, _action} -> new_state
      new_state -> new_state
    end
  end

  @spec copy_tab_path(state(), Tab.id()) :: state()
  defp copy_tab_path(state, id) do
    case tab_file_path(state, id) do
      nil ->
        EditorState.set_status(state, "Tab has no file path")

      path ->
        Clipboard.write_async(path)
        maybe_send_gui_clipboard_write(state, path)
        EditorState.set_status(state, "Copied #{path}")
    end
  end

  @spec maybe_send_gui_clipboard_write(state(), String.t()) :: :ok
  defp maybe_send_gui_clipboard_write(%{port_manager: nil}, _path), do: :ok

  defp maybe_send_gui_clipboard_write(state, path) do
    MingaEditor.Frontend.clipboard_write(state.port_manager, path)
  end

  @spec tab_file_path(state(), Tab.id()) :: String.t() | nil
  defp tab_file_path(state, id) do
    case EditorState.tab_bar(state) do
      %TabBar{} = tb -> tab_file_path_from_tab(state, tb, TabBar.get(tb, id))
      nil -> nil
    end
  end

  @spec tab_file_path_from_tab(state(), TabBar.t(), Tab.t() | nil) :: String.t() | nil
  defp tab_file_path_from_tab(_state, _tb, nil), do: nil
  defp tab_file_path_from_tab(_state, _tb, %Tab{kind: :agent}), do: nil

  defp tab_file_path_from_tab(state, %TabBar{active_id: active_id} = tb, %Tab{id: id}) do
    case id == active_id do
      true -> active_buffer_path(state)
      false -> inactive_tab_path(TabBar.get(tb, id))
    end
  end

  @spec active_buffer_path(state()) :: String.t() | nil
  defp active_buffer_path(%{workspace: %{buffers: %{active: buf}}}) when is_pid(buf) do
    Buffer.file_path(buf)
  end

  defp active_buffer_path(_state), do: nil

  @spec inactive_tab_path(Tab.t() | nil) :: String.t() | nil
  defp inactive_tab_path(%Tab{context: context}) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: pid}} when is_pid(pid) -> Buffer.file_path(pid)
      _ -> nil
    end
  end

  defp inactive_tab_path(_tab), do: nil

  @spec buffers_for_lsp_resync(state()) :: [pid()]
  defp buffers_for_lsp_resync(state) do
    active_buffers = Enum.filter(state.workspace.buffers.list, &is_pid/1)

    tab_buffers =
      case EditorState.tab_bar(state) do
        %MingaEditor.State.TabBar{tabs: tabs} -> Enum.flat_map(tabs, &tab_buffer_list/1)
        _ -> []
      end

    Enum.uniq(active_buffers ++ tab_buffers)
  end

  @spec tab_buffer_list(MingaEditor.State.Tab.t() | term()) :: [pid()]
  defp tab_buffer_list(%MingaEditor.State.Tab{context: context}) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{list: buffers}} -> Enum.filter(buffers, &is_pid/1)
      _ -> []
    end
  end

  defp tab_buffer_list(_tab), do: []

  @spec refresh_git_repo(String.t()) :: :ok
  defp refresh_git_repo(git_root) do
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

  @spec open_file_tree_entry_in_split(state(), non_neg_integer()) :: state()
  defp open_file_tree_entry_in_split(%{workspace: %{file_tree: %{tree: nil}}} = state, _index) do
    state
  end

  defp open_file_tree_entry_in_split(state, index) do
    state =
      state
      |> move_tree_cursor(index)
      |> unfocus_file_tree_for_split()

    case FileTree.selected_entry(state.workspace.file_tree.tree) do
      %{dir?: false, path: path} ->
        state
        |> Commands.Movement.execute(:split_vertical)
        |> Commands.Movement.execute(:window_right)
        |> open_file_by_path_in_active_window(path)

      %{dir?: true} ->
        state

      nil ->
        state
    end
  end

  @spec unfocus_file_tree_for_split(state()) :: state()
  defp unfocus_file_tree_for_split(state) do
    EditorState.update_workspace(state, fn workspace ->
      workspace
      |> SessionState.set_file_tree(MingaEditor.State.FileTree.unfocus(workspace.file_tree))
      |> SessionState.set_keymap_scope(:editor)
    end)
  end

  # Moves the file tree cursor to the given index and performs the action.
  @spec gui_tree_action(state(), non_neg_integer(), :click | :toggle) :: state()
  defp gui_tree_action(%{workspace: %{file_tree: %{tree: nil}}} = state, _index, _action),
    do: state

  defp gui_tree_action(state, index, action) do
    state = move_tree_cursor(state, index)

    case action do
      :click -> Commands.FileTree.open_or_toggle(state)
      :toggle -> Commands.FileTree.open_or_toggle(state)
    end
  end

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

  # Sets the manual workspace label to the project directory name.

  @spec set_vim_mode_state(state(), term()) :: state()
  defp set_vim_mode_state(state, new_ms) do
    EditorState.update_workspace(state, fn ws ->
      SessionState.update_editing(ws, &VimState.set_mode_state(&1, new_ms))
    end)
  end
end
