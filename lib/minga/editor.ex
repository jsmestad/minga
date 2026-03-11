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

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Completion
  alias Minga.Editor.AgentLifecycle
  alias Minga.Editor.BackgroundEvents
  alias Minga.Editor.BufferLifecycle
  alias Minga.Editor.Commands
  alias Minga.Editor.CompletionHandling
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.FileWatcherHelpers
  alias Minga.Editor.HighlightEvents
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.KeyDispatch
  alias Minga.Editor.Layout
  alias Minga.Editor.LspActions
  alias Minga.Editor.MessageLog
  alias Minga.Editor.Renderer
  alias Minga.Editor.Startup
  alias Minga.Editor.SurfaceSync
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.FileTree

  alias Minga.Input
  alias Minga.Mode

  alias Minga.Port.Manager, as: PortManager

  alias Minga.Project

  require Logger

  @typedoc "Options for starting the editor."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:port_manager, GenServer.server()}
          | {:buffer, pid()}
          | {:width, pos_integer()}
          | {:height, pos_integer()}

  alias Minga.Editor.State, as: EditorState

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

  # ── Server Callbacks ─────────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    state = Startup.build_initial_state(opts)
    state = init_surface(state)

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

    state = Startup.apply_config_options(state)
    Minga.Diagnostics.subscribe()

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
        FileWatcherHelpers.maybe_watch_buffer(pid)
        maybe_detect_project(file_path)
        maybe_record_file(file_path)
        new_state = Commands.add_buffer(state, pid)
        new_state = log_message(new_state, "Opened: #{file_path}")
        new_state = BufferLifecycle.lsp_buffer_opened(new_state, pid)
        new_state = BufferLifecycle.git_buffer_opened(new_state, pid)
        fire_hook(:after_open, [pid, file_path])
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
    {:reply, state.mode, state}
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

  def handle_call({:api_log_message, text}, _from, state) do
    new_state = log_message(state, text)
    {:reply, :ok, new_state}
  end

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:log_to_messages, text}, state) do
    {:noreply, log_message(state, text)}
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
    {:noreply, sync_surface_from_editor(new_state)}
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
    {:noreply, sync_surface_from_editor(new_state)}
  end

  # ── Key press dispatch ──
  # All key presses go through the focus stack via Input.Router.
  # The router walks ConflictPrompt → Picker → Completion → GlobalBindings → ModeFSM
  # and runs centralized post-key housekeeping (highlight sync, reparse,
  # completion, render) exactly once.
  def handle_info({:minga_input, {:key_press, codepoint, modifiers}}, state) do
    new_state = Input.Router.dispatch(state, codepoint, modifiers)
    {:noreply, sync_surface_from_editor(new_state)}
  end

  # ── Paste event (bracketed paste from TUI, Cmd+V from GUI) ──
  def handle_info({:minga_input, {:paste_event, text}}, state) do
    new_state = handle_paste_event(state, text)
    new_state = Renderer.render(new_state)
    {:noreply, sync_surface_from_editor(new_state)}
  end

  # ── File watcher notification ──
  def handle_info({:file_changed_on_disk, path}, state) do
    new_state = FileWatcherHelpers.handle_file_change(state, path)
    new_state = log_message(new_state, "External change detected: #{path}")
    new_state = Renderer.render(new_state)
    {:noreply, sync_surface_from_editor(new_state)}
  end

  def handle_info(
        {:minga_input, {:mouse_event, row, col, button, mods, event_type, click_count}},
        state
      ) do
    new_state =
      Input.Router.dispatch_mouse(state, row, col, button, mods, event_type, click_count)

    new_state = Renderer.render(new_state)
    {:noreply, sync_surface_from_editor(new_state)}
  end

  # Backward compat: 6-element mouse_event (no click_count)
  def handle_info(
        {:minga_input, {:mouse_event, row, col, button, mods, event_type}},
        state
      ) do
    new_state = Input.Router.dispatch_mouse(state, row, col, button, mods, event_type, 1)
    new_state = Renderer.render(new_state)
    {:noreply, sync_surface_from_editor(new_state)}
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

  def handle_info({tag, {:highlight_names, names}}, state)
      when tag in [:minga_highlight, :minga_input] do
    {:noreply, HighlightEvents.handle_names(state, names)}
  end

  def handle_info({tag, {:injection_ranges, ranges}}, state)
      when tag in [:minga_highlight, :minga_input] do
    {:noreply, HighlightEvents.handle_injection_ranges(state, ranges)}
  end

  def handle_info({tag, {:language_at_response, _request_id, _language}}, state)
      when tag in [:minga_highlight, :minga_input] do
    {:noreply, state}
  end

  def handle_info({tag, {:highlight_spans, version, spans}}, state)
      when tag in [:minga_highlight, :minga_input] do
    new_state = HighlightEvents.handle_spans(state, version, spans)
    {:noreply, sync_surface_from_editor(new_state)}
  end

  def handle_info({tag, {:grammar_loaded, _success, _name}}, state)
      when tag in [:minga_highlight, :minga_input] do
    {:noreply, state}
  end

  def handle_info({:minga_input, {:log_message, level, text}}, state) do
    prefix = MessageLog.frontend_prefix(state)
    new_state = log_message(state, "[#{prefix}/#{level}] #{text}")
    {:noreply, new_state}
  end

  # LSP debounced didChange timer fired — flush the change notification
  def handle_info({:lsp_did_change, buffer_pid}, state) do
    new_lsp = DocumentSync.flush_did_change(state.lsp, buffer_pid)
    {:noreply, %{state | lsp: new_lsp}}
  end

  # Completion debounce timer fired — send the actual completion request
  def handle_info({:completion_debounce, client, buffer_pid}, state) do
    new_bridge = CompletionTrigger.flush_debounce(state.completion_trigger, client, buffer_pid)
    {:noreply, %{state | completion_trigger: new_bridge}}
  end

  # LSP async response — route to the appropriate handler based on lsp.pending
  def handle_info({:lsp_response, ref, result}, state) do
    case Map.pop(state.lsp.pending, ref) do
      {:definition, pending} ->
        new_state = put_in(state.lsp.pending, pending)
        new_state = LspActions.handle_definition_response(new_state, result)
        new_state = Renderer.render(new_state)
        {:noreply, new_state}

      {:hover, pending} ->
        new_state = put_in(state.lsp.pending, pending)
        new_state = LspActions.handle_hover_response(new_state, result)
        new_state = Renderer.render(new_state)
        {:noreply, new_state}

      {nil, _} ->
        # Not a tracked request — try completion handler
        handle_lsp_completion_response(ref, result, state)
    end
  end

  # Diagnostics changed — re-render to update gutter signs and minibuffer hint.
  # Debounced because multiple diagnostics may arrive in rapid succession.
  def handle_info({:diagnostics_changed, _uri}, state) do
    {:noreply, schedule_render(state, 16)}
  end

  # Debounced render timer fired — perform the actual render.
  def handle_info(:debounced_render, state) do
    state = Renderer.render(state)
    {:noreply, sync_surface_from_editor(%{state | render_timer: nil})}
  end

  # ── Agent events ──────────────────────────────────────────────────────────
  #
  # All agent events are tagged with the session pid so we can route them
  # to the correct tab. Active-tab events are dispatched through the
  # AgentView surface's handle_event callback. Background-tab events
  # update the stored tab context directly.

  def handle_info({:agent_event, session_pid, event}, state) do
    case EditorState.route_agent_event(state, session_pid) do
      {:active, _tab} ->
        state = dispatch_surface_event(state, event)
        {:noreply, state}

      {:background, tab} ->
        state = BackgroundEvents.handle(state, tab, event)
        {:noreply, state}

      :not_found ->
        {:noreply, state}
    end
  end

  def handle_info(:agent_spinner_tick, state) do
    state = dispatch_surface_event(state, :spinner_tick)
    {:noreply, state}
  end

  @toast_duration_ms 3_000

  def handle_info(:dismiss_toast, state) do
    state = %{state | agentic: ViewState.dismiss_toast(state.agentic)}

    # If there's another toast in the queue, schedule its dismissal
    if ViewState.toast_visible?(state.agentic) do
      Process.send_after(self(), :dismiss_toast, @toast_duration_ms)
    end

    {:noreply, schedule_render(state, 16)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Tab bar, view state, capabilities, parser subscription helpers

  # ── Surface lifecycle ──────────────────────────────────────────────────────

  @doc """
  Applies a list of surface effects to the editor state.

  Surfaces return `{new_state, [effect()]}` from their callbacks.
  The Editor interprets each effect. This keeps surfaces testable as
  pure `state -> {state, effects}` functions.
  """
  @spec apply_effects(EditorState.t(), [Minga.Surface.effect()]) :: EditorState.t()
  def apply_effects(state, []), do: state

  def apply_effects(state, [effect | rest]) do
    state = apply_effect(state, effect)
    apply_effects(state, rest)
  end

  @spec apply_effect(EditorState.t(), Minga.Surface.effect()) :: EditorState.t()
  defp apply_effect(state, :render), do: schedule_render(state, 16)
  defp apply_effect(state, {:set_status, msg}) when is_binary(msg), do: %{state | status_msg: msg}

  defp apply_effect(state, {:open_file, path}) when is_binary(path),
    do: Commands.execute(state, {:edit_file, path})

  defp apply_effect(state, {:switch_buffer, pid}) when is_pid(pid) do
    case Enum.find_index(state.buffers.list, &(&1 == pid)) do
      nil -> state
      idx -> EditorState.switch_buffer(state, idx)
    end
  end

  defp apply_effect(state, {:push_overlay, mod}) when is_atom(mod),
    do: %{state | focus_stack: [mod | state.focus_stack]}

  defp apply_effect(state, {:pop_overlay, mod}) when is_atom(mod),
    do: %{state | focus_stack: List.delete(state.focus_stack, mod)}

  defp apply_effect(state, {:render, delay_ms}) when is_integer(delay_ms),
    do: schedule_render(state, delay_ms)

  defp apply_effect(state, {:log_message, msg}) when is_binary(msg), do: log_message(state, msg)
  defp apply_effect(state, :sync_agent_buffer), do: AgentLifecycle.sync_buffer(state)

  defp apply_effect(state, {:update_tab_label, _label}),
    do: AgentLifecycle.maybe_update_tab_label(state)

  @doc false
  defdelegate init_surface(state), to: SurfaceSync

  @spec sync_surface_from_editor(EditorState.t()) :: EditorState.t()
  defdelegate sync_surface_from_editor(state), to: SurfaceSync, as: :sync_from_editor

  @spec sync_editor_from_surface(EditorState.t()) :: EditorState.t()
  defdelegate sync_editor_from_surface(state), to: SurfaceSync, as: :sync_to_editor

  @spec dispatch_surface_event(EditorState.t(), term()) :: EditorState.t()
  def dispatch_surface_event(state, event) do
    {state, effects} = SurfaceSync.dispatch_event(state, event)
    apply_effects(state, effects)
  end

  # Tab bar, view state, capabilities, parser subscription helpers

  # Agent lifecycle helpers (session startup, auto-context, buffer sync,

  @spec handle_lsp_completion_response(reference(), term(), state()) :: {:noreply, state()}
  defp handle_lsp_completion_response(ref, result, state) do
    new_state = CompletionHandling.handle_response(state, ref, result)
    new_state = Renderer.render(new_state)
    {:noreply, new_state}
  end

  # ── Render scheduling ────────────────────────────────────────────────────────

  # Schedules a render within `delay_ms`. If a render is already scheduled,
  # this is a no-op (the pending render will pick up the latest state).
  # Use this instead of `Renderer.render/1` in paths that may fire rapidly
  # (e.g., diagnostics, LSP responses, file watcher events).
  @spec schedule_render(state(), non_neg_integer()) :: state()
  defp schedule_render(%{render_timer: ref} = state, _delay_ms) when is_reference(ref), do: state

  defp schedule_render(state, delay_ms) do
    ref = Process.send_after(self(), :debounced_render, delay_ms)
    %{state | render_timer: ref}
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

  # ── Project detection ───────────────────────────────────────────────────────

  @spec maybe_detect_project(String.t()) :: :ok
  defp maybe_detect_project(file_path) do
    Project.detect_and_set(file_path)
  catch
    :exit, _ -> :ok
  end

  @spec maybe_record_file(String.t()) :: :ok
  defp maybe_record_file(file_path) do
    Project.record_file(file_path)
  catch
    :exit, _ -> :ok
  end

  # ── Paste event routing ───────────────────────────────────────────────────

  @spec handle_paste_event(state(), String.t()) :: state()
  defp handle_paste_event(state, text)

  # Agent input is focused (split panel or full-screen agentic view): route paste to agent input
  defp handle_paste_event(
         %{agent: %{panel: %{input_focused: true}}} = state,
         text
       ) do
    Commands.Agent.input_paste(state, text)
  end

  # Insert mode in editor: insert text into the active buffer via bulk edit
  defp handle_paste_event(%{mode: :insert, buffers: %{active: buf}} = state, text)
       when is_pid(buf) do
    {line, col} = BufferServer.cursor(buf)
    BufferServer.apply_text_edit(buf, line, col, line, col, text)
    state
  end

  # Not in a paste-accepting context: log and ignore
  defp handle_paste_event(state, _text) do
    log_message(state, "Paste ignored (not in insert mode or agent input)")
  end

  # ── File tree helpers ───────────────────────────────────────────────────

  @doc false
  @spec do_file_tree_open(state(), pid(), String.t(), FileTree.t()) :: state()
  def do_file_tree_open(state, pid, path, tree) do
    FileWatcherHelpers.maybe_watch_buffer(pid)
    maybe_detect_project(path)
    maybe_record_file(path)
    new_state = Commands.add_buffer(state, pid)
    new_state = log_message(new_state, "Opened: #{path}")
    new_state = BufferLifecycle.lsp_buffer_opened(new_state, pid)
    new_state = BufferLifecycle.git_buffer_opened(new_state, pid)
    fire_hook(:after_open, [pid, path])
    put_in(new_state.file_tree.tree, FileTree.reveal(tree, path))
  end

  @spec log_message(state(), String.t()) :: state()
  defp log_message(state, text), do: MessageLog.log(state, text)

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

  # ── Config options ──────────────────────────────────────────────────────

  alias Minga.Config.Hooks, as: ConfigHooks

  @spec fire_hook(ConfigHooks.event(), [term()]) :: :ok
  defp fire_hook(event, args) do
    ConfigHooks.run(event, args)
  catch
    :exit, _ -> :ok
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
