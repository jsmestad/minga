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

  alias Minga.Agent.PanelState, as: AgentPanelState
  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Completion
  alias Minga.Config.Advice, as: ConfigAdvice
  alias Minga.Config.Loader, as: ConfigLoader
  alias Minga.Config.Options, as: ConfigOptions
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.LspActions
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.Mouse
  alias Minga.Editor.PickerUI
  alias Minga.Editor.Renderer
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.FileTree
  alias Minga.FileWatcher
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Mode
  alias Minga.Mode.CommandState
  alias Minga.Mode.EvalState
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol
  alias Minga.Project

  require Logger

  import Bitwise

  @ctrl Protocol.mod_ctrl()
  @alt Protocol.mod_alt()
  @escape 27
  @enter 13
  @tab 9

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
    port_manager = Keyword.get(opts, :port_manager, PortManager)
    file_watcher = Keyword.get(opts, :file_watcher)
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    buffer = Keyword.get(opts, :buffer)

    unless is_nil(port_manager) do
      try do
        PortManager.subscribe(port_manager)
      catch
        :exit, _ -> Logger.warning("Could not subscribe to port manager")
      end
    end

    # Register initial buffer with file watcher
    maybe_watch_buffer(file_watcher, buffer)

    buffers = if buffer, do: [buffer], else: []

    # Start special buffers (stored separately, not in buffer list)
    {messages_buf, scratch_buf} = start_special_buffers()

    # When no file is open, show scratch as the active buffer
    {active_buf, buffers} =
      case {buffer, scratch_buf} do
        {nil, pid} when is_pid(pid) -> {pid, []}
        {pid, _} when is_pid(pid) -> {pid, buffers}
        _ -> {nil, buffers}
      end

    active_idx = if active_buf && buffers != [], do: 0, else: 0

    viewport = Viewport.new(height, width)

    # Initialize the window tree with a single window
    initial_window_id = 1

    alias Minga.Editor.State.Buffers
    alias Minga.Editor.State.Windows

    initial_window =
      if active_buf do
        Window.new(initial_window_id, active_buf, height, width)
      else
        nil
      end

    windows =
      if initial_window, do: %{initial_window_id => initial_window}, else: %{}

    state = %EditorState{
      buffers: %Buffers{
        active: active_buf,
        list: buffers,
        active_index: active_idx,
        messages: messages_buf,
        scratch: scratch_buf
      },
      port_manager: port_manager,
      viewport: viewport,
      mode: :normal,
      mode_state: Mode.initial_state(),
      windows: %Windows{
        tree: WindowTree.new(initial_window_id),
        map: windows,
        active: initial_window_id,
        next_id: initial_window_id + 1
      }
    }

    # Redirect Logger and stderr to a log file when running with a real TUI.
    # In headless tests the port_manager is a pid (HeadlessPort), not the
    # registered PortManager atom, so we skip the redirect to keep ExUnit clean.
    tui_active? = port_manager == PortManager

    state =
      if tui_active? do
        log_path = Minga.LoggerHandler.install()
        state = log_message(state, "Editor started")
        log_message(state, "Log file: #{log_path}")
      else
        log_message(state, "Editor started")
      end

    # Apply user config options
    state = apply_config_options(state)

    # Subscribe to diagnostic changes for re-rendering gutter signs
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
        maybe_watch_buffer(file_watcher_pid(), pid)
        maybe_detect_project(file_path)
        maybe_record_file(file_path)
        new_state = Commands.add_buffer(state, pid)
        new_state = log_message(new_state, "Opened: #{file_path}")
        new_state = lsp_buffer_opened(new_state, pid)
        new_state = git_buffer_opened(new_state, pid)
        fire_hook(:after_open, [pid, file_path])
        Renderer.render(new_state)
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

    Renderer.render(new_state)
    {:reply, result, new_state}
  end

  def handle_call({:api_execute_command, cmd}, _from, state) do
    new_state = dispatch_command(state, cmd)
    Renderer.render(new_state)
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
    Renderer.render(state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:minga_input, {:ready, width, height}}, state) do
    new_state = %{state | viewport: Viewport.new(height, width)}
    Renderer.render(new_state)
    # Setup highlighting after first paint with correct viewport
    send(self(), :setup_highlight)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:resize, width, height}}, state) do
    new_state = %{state | viewport: Viewport.new(height, width)}
    new_state = resize_all_windows(new_state)
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  # ── Conflict prompt: intercept r/k before normal key handling ──
  def handle_info(
        {:minga_input, {:key_press, ?r, _mods}},
        %{pending_conflict: {buf, _path}} = state
      )
      when is_pid(buf) do
    BufferServer.reload(buf)
    name = Path.basename(BufferServer.file_path(buf) || "buffer")

    new_state = %{
      state
      | pending_conflict: nil,
        status_msg: "#{name} reloaded (changed on disk)"
    }

    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info(
        {:minga_input, {:key_press, ?k, _mods}},
        %{pending_conflict: {buf, _path}} = state
      )
      when is_pid(buf) do
    # Keep local edits — update stored mtime+size so the prompt doesn't repeat
    buf_state = :sys.get_state(buf)

    case File.stat(buf_state.file_path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} ->
        :sys.replace_state(buf, fn s -> %{s | mtime: mtime, file_size: size} end)

      {:error, _} ->
        :ok
    end

    new_state = %{state | pending_conflict: nil, status_msg: nil}
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:key_press, _cp, _mods}}, %{pending_conflict: {_, _}} = state) do
    # Any other key while conflict prompt is active — ignore
    {:noreply, state}
  end

  # ── Agent panel key interception ──
  # When the agent panel is visible and input is focused, ALL keystrokes
  # route here. Only Escape can unfocus the input. Ctrl+Q and Ctrl+S are
  # handled directly. Unrecognized keys are silently ignored (never
  # forwarded to the mode FSM, which would cause accidental unfocusing).
  def handle_info(
        {:minga_input, {:key_press, codepoint, modifiers}},
        %{agent_panel: %{visible: true, input_focused: true}} = state
      ) do
    new_state = handle_agent_key(%{state | status_msg: nil}, codepoint, modifiers)
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  # ── File tree key interception ──
  def handle_info(
        {:minga_input, {:key_press, codepoint, modifiers}},
        %{file_tree: %FileTree{}, file_tree_focused: true} = state
      ) do
    old_buffer = state.buffers.active

    case handle_file_tree_key(state, codepoint, modifiers) do
      :passthrough ->
        # Key not handled by tree; unfocus and forward to normal processing
        new_state = %{state | file_tree_focused: false}
        send(self(), {:minga_input, {:key_press, codepoint, modifiers}})
        {:noreply, new_state}

      new_state ->
        new_state = maybe_reset_highlight(new_state, old_buffer)
        Renderer.render(new_state)
        {:noreply, new_state}
    end
  end

  # ── File watcher notification ──
  def handle_info({:file_changed_on_disk, path}, state) do
    new_state = handle_file_change(state, path)
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info(
        {:minga_input, {:key_press, codepoint, modifiers}},
        %{picker_ui: %{picker: picker}} = state
      )
      when is_struct(picker, Minga.Picker) do
    old_buffer = state.buffers.active

    new_state =
      case PickerUI.handle_key(%{state | status_msg: nil}, codepoint, modifiers) do
        {s, {:execute_command, cmd}} -> dispatch_command(s, cmd)
        s -> s
      end

    new_state = maybe_reset_highlight(new_state, old_buffer)
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  # Completion popup key interception — when popup is visible in insert mode,
  # intercept navigation and accept keys before normal insert mode handling.
  def handle_info(
        {:minga_input, {:key_press, codepoint, modifiers}},
        %{mode: :insert, completion: %Completion{} = completion} = state
      ) do
    case handle_completion_key(state, completion, codepoint, modifiers) do
      {:handled, new_state} ->
        Renderer.render(new_state)
        {:noreply, new_state}

      :passthrough ->
        # Not a completion key — fall through to normal insert handling
        buf_version_before = buffer_version(state)
        new_state = handle_key(%{state | status_msg: nil}, codepoint, modifiers)
        new_state = maybe_reset_highlight(new_state, state.buffers.active)
        new_state = maybe_reparse(new_state, buf_version_before)

        # After insert mode edits, update completion filter or trigger new completions
        new_state = maybe_update_completion(new_state, codepoint, modifiers)

        Renderer.render(new_state)
        {:noreply, new_state}
    end
  end

  def handle_info({:minga_input, {:key_press, codepoint, modifiers}}, state) do
    buf_version_before = buffer_version(state)
    old_mode = state.mode
    new_state = handle_key(%{state | status_msg: nil}, codepoint, modifiers)
    new_state = maybe_reset_highlight(new_state, state.buffers.active)
    new_state = maybe_reparse(new_state, buf_version_before)

    # Trigger completion after insert mode edits (no active popup)
    new_state =
      if new_state.mode == :insert and old_mode == :insert do
        maybe_update_completion(new_state, codepoint, modifiers)
      else
        # Dismiss completion when leaving insert mode
        dismiss_completion(new_state)
      end

    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:mouse_event, row, col, button, _mods, event_type}}, state) do
    new_state = Mouse.handle(state, row, col, button, event_type)
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:whichkey_timeout, ref}, %{whichkey: %{timer: ref}} = state) do
    new_state = put_in(state.whichkey.show, true)
    Renderer.render(new_state)
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

  # ── Highlight events from Zig ────────────────────────────────────────────────

  def handle_info({:minga_input, {:highlight_names, names}}, state) do
    new_state = HighlightSync.handle_names(state, names)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:injection_ranges, ranges}}, state) do
    new_state =
      if state.buffers.active do
        %{state | injection_ranges: Map.put(state.injection_ranges, state.buffers.active, ranges)}
      else
        state
      end

    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:language_at_response, _request_id, _language}}, state) do
    # Reserved for future use (synchronous language queries)
    {:noreply, state}
  end

  def handle_info({:minga_input, {:highlight_spans, version, spans}}, state) do
    new_state = HighlightSync.handle_spans(state, version, spans)

    # Cache the updated highlights for this buffer
    new_state =
      if new_state.buffers.active do
        hl = new_state.highlight

        %{
          new_state
          | highlight: %{hl | cache: Map.put(hl.cache, new_state.buffers.active, hl.current)}
        }
      else
        new_state
      end

    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:grammar_loaded, _success, _name}}, state) do
    {:noreply, state}
  end

  def handle_info({:minga_input, {:log_message, level, text}}, state) do
    new_state = log_message(state, "[ZIG/#{level}] #{text}")
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

  # LSP async response — route to the appropriate handler based on lsp_pending
  def handle_info({:lsp_response, ref, result}, state) do
    case Map.pop(state.lsp_pending, ref) do
      {:definition, pending} ->
        new_state = %{state | lsp_pending: pending}
        new_state = LspActions.handle_definition_response(new_state, result)
        Renderer.render(new_state)
        {:noreply, new_state}

      {:hover, pending} ->
        new_state = %{state | lsp_pending: pending}
        new_state = LspActions.handle_hover_response(new_state, result)
        Renderer.render(new_state)
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
    Renderer.render(state)
    {:noreply, %{state | render_timer: nil}}
  end

  # ── Agent events ──────────────────────────────────────────────────────────

  def handle_info({:agent_event, {:status_changed, status}}, state) do
    state = %{state | agent_status: status}

    # Start/stop spinner timer based on status
    state =
      case status do
        s when s in [:thinking, :tool_executing] ->
          start_spinner_timer(state)

        _ ->
          stop_spinner_timer(state)
      end

    Renderer.render(state)
    {:noreply, state}
  end

  def handle_info({:agent_event, {:text_delta, _delta}}, state) do
    # Auto-scroll and re-render on new text
    state = %{state | agent_panel: AgentPanelState.scroll_to_bottom(state.agent_panel)}
    {:noreply, schedule_render(state, 16)}
  end

  def handle_info({:agent_event, {:thinking_delta, _delta}}, state) do
    {:noreply, schedule_render(state, 50)}
  end

  def handle_info({:agent_event, :messages_changed}, state) do
    state = %{state | agent_panel: AgentPanelState.scroll_to_bottom(state.agent_panel)}
    {:noreply, schedule_render(state, 16)}
  end

  def handle_info({:agent_event, {:tool_update, _id}}, state) do
    {:noreply, schedule_render(state, 50)}
  end

  def handle_info({:agent_event, {:error, message}}, state) do
    state = %{state | agent_status: :error, agent_error: message}
    Renderer.render(state)
    {:noreply, state}
  end

  def handle_info(:agent_spinner_tick, state) do
    if state.agent_panel.visible and state.agent_status in [:thinking, :tool_executing] do
      state = %{state | agent_panel: AgentPanelState.tick_spinner(state.agent_panel)}
      {:noreply, schedule_render(state, 16)}
    else
      {:noreply, stop_spinner_timer(state)}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec start_spinner_timer(state()) :: state()
  defp start_spinner_timer(%{agent_spinner_timer: nil} = state) do
    timer = :timer.send_interval(100, :agent_spinner_tick)
    %{state | agent_spinner_timer: timer}
  end

  defp start_spinner_timer(state), do: state

  @spec stop_spinner_timer(state()) :: state()
  defp stop_spinner_timer(%{agent_spinner_timer: nil} = state), do: state

  defp stop_spinner_timer(%{agent_spinner_timer: timer} = state) do
    case timer do
      {:ok, ref} -> :timer.cancel(ref)
      ref when is_reference(ref) -> :timer.cancel(ref)
      _ -> :ok
    end

    %{state | agent_spinner_timer: nil}
  end

  @spec handle_lsp_completion_response(reference(), term(), state()) :: {:noreply, state()}
  defp handle_lsp_completion_response(ref, result, state) do
    buffer_pid = state.buffers.active

    case buffer_pid do
      nil ->
        {:noreply, state}

      _ ->
        {new_bridge, completion} =
          CompletionTrigger.handle_response(state.completion_trigger, ref, result, buffer_pid)

        new_state = %{state | completion_trigger: new_bridge}

        new_state =
          case completion do
            nil -> new_state
            %Completion{} -> %{new_state | completion: completion}
          end

        Renderer.render(new_state)
        {:noreply, new_state}
    end
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

  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: state()

  # Global bindings — processed before the Mode FSM.
  # Ctrl+S → save (works in any mode).
  # ── Agent panel input routing ─────────────────────────────────────────────
  # ── Agent panel key dispatch ──────────────────────────────────────────────
  # All keys handled inline. Only Escape unfocuses. Unrecognized keys are
  # swallowed so stray terminal events can never break focus.

  @spec handle_agent_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()

  # Ctrl+Q: quit (unfocus first, then forward the quit key)
  defp handle_agent_key(state, ?q, mods) when band(mods, @ctrl) != 0 do
    send(self(), {:minga_input, {:key_press, ?q, mods}})
    %{state | agent_panel: AgentPanelState.set_input_focused(state.agent_panel, false)}
  end

  # Ctrl+S: save current buffer
  defp handle_agent_key(state, ?s, mods) when band(mods, @ctrl) != 0 do
    if state.buffers.active do
      case BufferServer.save(state.buffers.active) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Save failed: #{inspect(reason)}")
      end
    end

    _ = mods
    state
  end

  # Ctrl+C: submit prompt
  defp handle_agent_key(state, ?c, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.submit_prompt(state)
  end

  # Ctrl+D: scroll chat down
  defp handle_agent_key(state, ?d, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.scroll_chat_down(state)
  end

  # Ctrl+U: scroll chat up
  defp handle_agent_key(state, ?u, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.scroll_chat_up(state)
  end

  # Escape: unfocus the input (return to normal editing)
  defp handle_agent_key(state, 27, _mods) do
    %{state | agent_panel: AgentPanelState.set_input_focused(state.agent_panel, false)}
  end

  # Backspace
  defp handle_agent_key(state, 127, _mods) do
    AgentCommands.input_backspace(state)
  end

  # Enter: submit prompt
  defp handle_agent_key(state, 13, _mods) do
    AgentCommands.submit_prompt(state)
  end

  # Printable characters (only unmodified or shift-modified, not Ctrl/Alt)
  defp handle_agent_key(state, cp, mods)
       when cp >= 32 and band(mods, @ctrl) == 0 and band(mods, @alt) == 0 do
    char = <<cp::utf8>>
    AgentCommands.input_char(state, char)
  end

  # Everything else (arrows, function keys, terminal responses): silently ignore
  defp handle_agent_key(state, _cp, _mods), do: state

  # Ctrl+S → save (works in any mode, including agent panel focus).
  defp handle_key(state, ?s, mods) when band(mods, @ctrl) != 0 do
    if state.buffers.active do
      case BufferServer.save(state.buffers.active) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Save failed: #{inspect(reason)}")
      end
    end

    state
  end

  # Ctrl+Q → quit (works in any mode).
  defp handle_key(state, ?q, mods) when band(mods, @ctrl) != 0 do
    System.stop(0)
    state
  end

  # All other keys go through the Mode FSM.
  defp handle_key(state, codepoint, modifiers) do
    key = {codepoint, modifiers}
    old_mode = state.mode
    {new_mode, commands, new_mode_state} = Mode.process(old_mode, key, state.mode_state)

    # ── Change recording ─────────────────────────────────────────────────
    # Record keys for dot repeat, unless we're currently replaying.
    state = maybe_record_change(state, old_mode, new_mode, commands, key)

    # ── Macro recording ──────────────────────────────────────────────────
    # Record keys into macro register if actively recording (and not replaying).
    state = maybe_record_macro_key(state, key, commands)

    # Guard: block insert/replace transitions on read-only buffers.
    {new_mode, commands, new_mode_state, state} =
      if new_mode in [:insert, :replace] and state.buffers.active != nil and
           BufferServer.read_only?(state.buffers.active) do
        {:normal, [], Mode.initial_state(), %{state | status_msg: "Buffer is read-only"}}
      else
        {new_mode, commands, new_mode_state, state}
      end

    # When transitioning INTO visual or command mode, adjust mode_state.
    new_mode_state =
      adjust_mode_state_on_transition(new_mode_state, old_mode, new_mode, state)

    base_state = %{state | mode: new_mode, mode_state: new_mode_state}

    # Fire mode change hook and break undo coalescing so the next edit
    # in the new mode starts a fresh undo entry.
    if old_mode != new_mode do
      if base_state.buffers.active,
        do: BufferServer.break_undo_coalescing(base_state.buffers.active)

      fire_hook(:on_mode_change, [old_mode, new_mode])
    end

    after_commands =
      Enum.reduce(commands, base_state, fn cmd, acc ->
        dispatch_command(acc, cmd)
      end)

    # After commands have executed (they may need the old mode_state, e.g.
    # VisualState for delete_visual_selection), clean up the mode_state
    # if we've transitioned back to Normal from a different mode.
    # Skip cleanup if a command changed the mode to something other than
    # what the FSM transition requested (e.g. substitute confirm, search prompt).
    after_commands =
      if new_mode == :normal and old_mode != :normal and after_commands.mode == :normal do
        case after_commands.mode_state do
          %Mode.State{} -> after_commands
          _ -> %{after_commands | mode_state: Mode.initial_state()}
        end
      else
        after_commands
      end

    after_commands
  end

  # ── Change recording helpers ───────────────────────────────────────────────

  # No-op during replay — don't overwrite the stored change.
  @spec maybe_record_change(
          state(),
          Mode.mode(),
          Mode.mode(),
          [Mode.command()],
          {non_neg_integer(), non_neg_integer()}
        ) :: state()
  defp maybe_record_change(%{change_recorder: %{replaying: true}} = state, _, _, _, _), do: state

  defp maybe_record_change(%{change_recorder: rec} = state, old_mode, new_mode, commands, key) do
    rec = update_recorder(rec, old_mode, new_mode, commands, key)
    %{state | change_recorder: rec}
  end

  # ── Already recording: record key and check for change end ──

  @spec update_recorder(
          ChangeRecorder.t(),
          Mode.mode(),
          Mode.mode(),
          [Mode.command()],
          ChangeRecorder.key()
        ) :: ChangeRecorder.t()
  defp update_recorder(%{recording: true} = rec, old_mode, :normal, _commands, key)
       when old_mode in [:insert, :replace, :operator_pending] do
    rec |> ChangeRecorder.record_key(key) |> ChangeRecorder.stop_recording()
  end

  defp update_recorder(%{recording: true} = rec, _old_mode, _new_mode, _commands, key) do
    ChangeRecorder.record_key(rec, key)
  end

  # ── From Normal: mode transition starts recording ──

  defp update_recorder(rec, :normal, new_mode, _commands, key)
       when new_mode in [:insert, :replace, :operator_pending] do
    rec |> ChangeRecorder.start_recording() |> ChangeRecorder.record_key(key)
  end

  # ── From Normal: single-key edit stays in Normal ──

  defp update_recorder(rec, :normal, :normal, commands, key) do
    do_update_normal_to_normal(rec, commands, key)
  end

  # ── From OperatorPending: record and handle completion ──

  defp update_recorder(rec, :operator_pending, :normal, _commands, key) do
    rec
    |> ChangeRecorder.start_recording_if_not()
    |> ChangeRecorder.record_key(key)
    |> ChangeRecorder.stop_recording()
  end

  defp update_recorder(rec, :operator_pending, :insert, _commands, key) do
    rec
    |> ChangeRecorder.start_recording_if_not()
    |> ChangeRecorder.record_key(key)
  end

  defp update_recorder(rec, :operator_pending, :operator_pending, _commands, key) do
    rec
    |> ChangeRecorder.start_recording_if_not()
    |> ChangeRecorder.record_key(key)
  end

  defp update_recorder(rec, :operator_pending, _new_mode, _commands, _key) do
    ChangeRecorder.cancel_recording(rec)
  end

  # ── All other mode transitions: no recording changes ──

  defp update_recorder(rec, _old_mode, _new_mode, _commands, _key), do: rec

  # ── Mode state adjustments on transition ────────────────────────────────────

  # Entering visual mode: capture cursor as selection anchor.
  @spec adjust_mode_state_on_transition(Mode.state(), Mode.mode(), Mode.mode(), state()) ::
          Mode.state()
  defp adjust_mode_state_on_transition(mode_state, old_mode, :visual, %{buffers: %{active: buf}})
       when old_mode != :visual and is_pid(buf) do
    anchor = BufferServer.cursor(buf)
    %{mode_state | visual_anchor: anchor}
  end

  # Entering command mode: ensure CommandState.
  defp adjust_mode_state_on_transition(mode_state, old_mode, :command, _state)
       when old_mode != :command do
    case mode_state do
      %CommandState{} -> mode_state
      _ -> %CommandState{}
    end
  end

  # Entering eval mode: ensure EvalState.
  defp adjust_mode_state_on_transition(mode_state, old_mode, :eval, _state)
       when old_mode != :eval do
    case mode_state do
      %EvalState{} -> mode_state
      _ -> %EvalState{}
    end
  end

  # Entering search mode: capture cursor for restore on Escape.
  defp adjust_mode_state_on_transition(
         %Minga.Mode.SearchState{} = mode_state,
         old_mode,
         :search,
         %{buffers: %{active: buf}}
       )
       when old_mode != :search and is_pid(buf) do
    cursor = BufferServer.cursor(buf)
    %{mode_state | original_cursor: cursor}
  end

  # All other transitions: pass through.
  defp adjust_mode_state_on_transition(mode_state, _old_mode, _new_mode, _state), do: mode_state

  # Handle Normal → Normal: detect edits, pending keys, or motions.
  @spec do_update_normal_to_normal(ChangeRecorder.t(), [Mode.command()], ChangeRecorder.key()) ::
          ChangeRecorder.t()

  # No commands (count accumulation, pending prefix) — buffer the key.
  defp do_update_normal_to_normal(rec, [], key) do
    ChangeRecorder.buffer_pending_key(rec, key)
  end

  # Commands present — check if any are editing commands.
  defp do_update_normal_to_normal(rec, commands, key) do
    case Enum.any?(commands, &editing_command?/1) do
      true ->
        rec
        |> ChangeRecorder.start_recording()
        |> ChangeRecorder.record_key(key)
        |> ChangeRecorder.stop_recording()

      false ->
        ChangeRecorder.clear_pending(rec)
    end
  end

  @spec editing_command?(Mode.command()) :: boolean()
  defp editing_command?(:delete_at), do: true
  defp editing_command?(:delete_before), do: true
  defp editing_command?(:delete_line), do: true
  defp editing_command?(:change_line), do: true
  defp editing_command?(:join_lines), do: true
  defp editing_command?(:toggle_case), do: true
  defp editing_command?(:indent_line), do: true
  defp editing_command?(:dedent_line), do: true
  defp editing_command?(:paste_after), do: true
  defp editing_command?(:paste_before), do: true
  defp editing_command?({:replace_char, _}), do: true
  defp editing_command?({:delete_motion, _}), do: true
  defp editing_command?({:indent_lines, _}), do: true
  defp editing_command?({:dedent_lines, _}), do: true
  defp editing_command?(_), do: false

  # ── Dot repeat replay ──────────────────────────────────────────────────────

  @spec replay_last_change(state(), non_neg_integer() | nil) :: state()
  defp replay_last_change(%{change_recorder: rec} = state, count) do
    case ChangeRecorder.get_last_change(rec) do
      nil ->
        # No prior change — no-op.
        state

      keys ->
        # If a count was given with `.` (e.g. `3.`), replace the original
        # change's count prefix with the new one.
        keys = ChangeRecorder.replace_count(keys, count)

        # Enter replay mode — suppresses recording.
        rec = ChangeRecorder.start_replay(rec)
        state = %{state | change_recorder: rec}

        # Feed each key through handle_key sequentially.
        state =
          Enum.reduce(keys, state, fn {codepoint, modifiers}, acc ->
            handle_key(acc, codepoint, modifiers)
          end)

        # Exit replay mode.
        rec = ChangeRecorder.stop_replay(state.change_recorder)
        %{state | change_recorder: rec}
    end
  end

  # ── Command execution ────────────────────────────────────────────────────────

  # Detect active buffer change: save old highlights to cache, restore or setup new.
  @spec maybe_reset_highlight(state(), pid() | nil) :: state()
  defp maybe_reset_highlight(state, old_buffer) do
    new_buffer = state.buffers.active

    if new_buffer != old_buffer and new_buffer != nil do
      # Save current highlights for the old buffer
      hl = state.highlight

      cache =
        if old_buffer != nil and hl.current.capture_names != [] do
          Map.put(hl.cache, old_buffer, hl.current)
        else
          hl.cache
        end

      # Restore cached highlights for the new buffer, or setup fresh
      case Map.get(cache, new_buffer) do
        nil ->
          send(self(), :setup_highlight)

          %{
            state
            | highlight: %{hl | current: Minga.Highlight.from_theme(state.theme), cache: cache}
          }

        cached ->
          %{state | highlight: %{hl | current: cached, cache: cache}}
      end
    else
      state
    end
  end

  # Re-parse buffer for syntax highlighting after content-mutating keys.
  # Compares the buffer's mutation version before/after key handling to detect
  # any content change — covers insert mode, normal-mode operators (dd, p, x,
  # >>, <<, etc.), undo/redo, and any other mutation path.
  @spec maybe_reparse(state(), non_neg_integer()) :: state()
  defp maybe_reparse(state, version_before) do
    content_changed = buffer_version(state) != version_before

    state =
      if content_changed do
        state
        |> lsp_buffer_changed()
        |> git_buffer_changed()
      else
        state
      end

    if content_changed and state.highlight.current.capture_names != [] do
      HighlightSync.request_reparse(state)
    else
      state
    end
  end

  @spec buffer_version(state()) :: non_neg_integer()
  defp buffer_version(%{buffers: %{active: nil}}), do: 0
  defp buffer_version(%{buffers: %{active: buf}}), do: BufferServer.version(buf)

  @spec dispatch_command(state(), Mode.command()) :: state()
  defp dispatch_command(state, cmd) do
    old_buffer = state.buffers.active
    cmd_name = command_name(cmd)

    execute = fn s ->
      case Commands.execute(s, cmd) do
        {s2, {:dot_repeat, count}} -> replay_last_change(s2, count)
        {s2, {:replay_macro, register}} -> replay_macro(s2, register)
        {s2, {:whichkey_update, wk}} -> %{s2 | whichkey: wk}
        s2 -> s2
      end
    end

    result = ConfigAdvice.wrap(cmd_name, execute).(state)

    lsp_after_command(result, cmd, old_buffer)
  end

  # Extracts the command name atom from a command (which may be an atom or tuple).
  @spec command_name(Mode.command()) :: atom()
  defp command_name(cmd) when is_atom(cmd), do: cmd
  defp command_name(cmd) when is_tuple(cmd), do: elem(cmd, 0)
  defp command_name(cmd) when is_list(cmd), do: :multi
  defp command_name(_cmd), do: :unknown

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

  # ── File watcher helpers ──────────────────────────────────────────────────

  @spec handle_file_change(state(), String.t()) :: state()
  defp handle_file_change(state, path) do
    case find_buffer_for_path(state, path) do
      nil ->
        state

      buf ->
        buf_state = :sys.get_state(buf)
        {disk_mtime, disk_size} = file_stat(path)

        cond do
          # Can't stat or no stored mtime — skip
          disk_mtime == nil or buf_state.mtime == nil ->
            state

          # No change detected (same mtime AND same size)
          disk_mtime == buf_state.mtime and disk_size == buf_state.file_size ->
            state

          # Unmodified buffer — silent reload
          not buf_state.dirty ->
            BufferServer.reload(buf)
            name = Path.basename(path)
            %{state | status_msg: "#{name} reloaded (changed on disk)"}

          # Modified buffer — prompt user
          true ->
            name = Path.basename(path)

            %{
              state
              | pending_conflict: {buf, path},
                status_msg: "#{name} changed on disk. [r]eload / [k]eep"
            }
        end
    end
  end

  @spec find_buffer_for_path(state(), String.t()) :: pid() | nil
  defp find_buffer_for_path(%{buffers: %{list: buffers}}, path) do
    expanded = Path.expand(path)

    Enum.find(buffers, fn buf ->
      Process.alive?(buf) and BufferServer.file_path(buf) == expanded
    end)
  end

  @spec maybe_watch_buffer(GenServer.server() | nil, pid() | nil) :: :ok
  defp maybe_watch_buffer(nil, _buf), do: :ok
  defp maybe_watch_buffer(_watcher, nil), do: :ok

  defp maybe_watch_buffer(watcher, buf) do
    case BufferServer.file_path(buf) do
      nil -> :ok
      path -> FileWatcher.watch_path(watcher, path)
    end
  end

  @spec file_watcher_pid() :: pid() | nil
  defp file_watcher_pid do
    case Process.whereis(FileWatcher) do
      nil -> nil
      pid -> pid
    end
  end

  @spec file_stat(String.t()) :: {integer() | nil, non_neg_integer() | nil}
  defp file_stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _} -> {nil, nil}
    end
  end

  # ── Macro recording helpers ───────────────────────────────────────────────

  @spec maybe_record_macro_key(
          state(),
          {non_neg_integer(), non_neg_integer()},
          [Mode.command()]
        ) :: state()
  defp maybe_record_macro_key(%{macro_recorder: %{replaying: true}} = state, _key, _cmds),
    do: state

  defp maybe_record_macro_key(%{macro_recorder: rec} = state, key, commands) do
    case MacroRecorder.recording?(rec) do
      {true, _reg} ->
        # Don't record the `q` that stops recording
        has_stop? = Enum.any?(commands, &match?(:toggle_macro_recording, &1))

        if has_stop? do
          state
        else
          %{state | macro_recorder: MacroRecorder.record_key(rec, key)}
        end

      false ->
        state
    end
  end

  @spec replay_macro(state(), String.t()) :: state()
  defp replay_macro(%{macro_recorder: rec} = state, register) do
    case MacroRecorder.get_macro(rec, register) do
      nil ->
        state

      keys ->
        rec = MacroRecorder.start_replay(rec)
        state = %{state | macro_recorder: rec}

        state =
          Enum.reduce(keys, state, fn {codepoint, modifiers}, acc ->
            handle_key(acc, codepoint, modifiers)
          end)

        rec = MacroRecorder.stop_replay(state.macro_recorder)
        %{state | macro_recorder: rec}
    end
  end

  # ── File tree key handling ──────────────────────────────────────────────

  @spec handle_file_tree_key(state(), non_neg_integer(), non_neg_integer()) ::
          state() | :passthrough

  # q or Escape — close the tree
  defp handle_file_tree_key(state, cp, _mods) when cp in [?q, @escape] do
    %{state | file_tree: nil, file_tree_focused: false}
  end

  # j — move down
  defp handle_file_tree_key(%{file_tree: tree} = state, ?j, _mods) do
    %{state | file_tree: FileTree.move_down(tree)}
  end

  # k — move up
  defp handle_file_tree_key(%{file_tree: tree} = state, ?k, _mods) do
    %{state | file_tree: FileTree.move_up(tree)}
  end

  # Enter — open file or toggle directory
  defp handle_file_tree_key(%{file_tree: tree} = state, @enter, _mods) do
    case FileTree.selected_entry(tree) do
      %{dir?: true} ->
        %{state | file_tree: FileTree.toggle_expand(tree)}

      %{dir?: false, path: path} ->
        # Open the file and return focus to editor
        state = %{state | file_tree_focused: false}

        case Commands.start_buffer(path) do
          {:ok, pid} ->
            maybe_watch_buffer(file_watcher_pid(), pid)
            maybe_detect_project(path)
            maybe_record_file(path)
            new_state = Commands.add_buffer(state, pid)
            new_state = log_message(new_state, "Opened: #{path}")
            new_state = lsp_buffer_opened(new_state, pid)
            new_state = git_buffer_opened(new_state, pid)
            fire_hook(:after_open, [pid, path])
            %{new_state | file_tree: FileTree.reveal(tree, path)}

          {:error, _} ->
            state
        end

      nil ->
        state
    end
  end

  # Tab — same as Enter for directories
  defp handle_file_tree_key(%{file_tree: tree} = state, @tab, _mods) do
    %{state | file_tree: FileTree.toggle_expand(tree)}
  end

  # h — collapse (or jump to parent)
  defp handle_file_tree_key(%{file_tree: tree} = state, ?h, _mods) do
    %{state | file_tree: FileTree.collapse(tree)}
  end

  # l — expand (or move into first child)
  defp handle_file_tree_key(%{file_tree: tree} = state, ?l, _mods) do
    %{state | file_tree: FileTree.expand(tree)}
  end

  # H — toggle hidden files
  defp handle_file_tree_key(%{file_tree: tree} = state, ?H, _mods) do
    %{state | file_tree: FileTree.toggle_hidden(tree)}
  end

  # r or g — refresh
  defp handle_file_tree_key(%{file_tree: tree} = state, cp, _mods) when cp in [?r, ?g] do
    %{state | file_tree: FileTree.refresh(tree)}
  end

  # Any other key — pass through to normal mode processing
  defp handle_file_tree_key(_state, _cp, _mods), do: :passthrough

  # ── Special buffers ──────────────────────────────────────────────────────

  @spec start_special_buffers() :: {pid() | nil, pid() | nil}
  defp start_special_buffers do
    messages_buf =
      case DynamicSupervisor.start_child(
             Minga.Buffer.Supervisor,
             {BufferServer,
              content: "",
              buffer_name: "*Messages*",
              read_only: true,
              unlisted: true,
              persistent: true}
           ) do
        {:ok, pid} -> pid
        _ -> nil
      end

    scratch_filetype = ConfigOptions.get(:scratch_filetype)

    scratch_content =
      "# This buffer is for notes you don't want to save.\n# It will persist across buffer switches.\n\n"

    scratch_buf =
      case DynamicSupervisor.start_child(
             Minga.Buffer.Supervisor,
             {BufferServer,
              content: scratch_content,
              buffer_name: "*scratch*",
              unlisted: true,
              persistent: true,
              filetype: scratch_filetype}
           ) do
        {:ok, pid} -> pid
        _ -> nil
      end

    {messages_buf, scratch_buf}
  end

  # ── Message logging ──────────────────────────────────────────────────────

  @max_messages_lines 1000

  @doc false
  @spec log_message(state(), String.t()) :: state()
  defp log_message(%{buffers: %{messages: nil}} = state, _text), do: state

  defp log_message(%{buffers: %{messages: buf}} = state, text) do
    time = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    BufferServer.append(buf, "[#{time}] #{text}\n")

    # Trim to max lines
    line_count = BufferServer.line_count(buf)

    if line_count > @max_messages_lines do
      excess = line_count - @max_messages_lines
      # Read remaining content and replace
      content = BufferServer.content(buf)
      lines = String.split(content, "\n")
      trimmed = lines |> Enum.drop(excess) |> Enum.join("\n")
      # Direct state manipulation to bypass read-only for trim
      :sys.replace_state(buf, fn s ->
        %{s | document: Document.new(trimmed)}
      end)
    end

    state
  end

  # ── Window resize ────────────────────────────────────────────────────────

  @spec resize_all_windows(state()) :: state()
  defp resize_all_windows(%{windows: %{tree: nil}} = state), do: state

  defp resize_all_windows(state) do
    screen = EditorState.screen_rect(state)
    layouts = WindowTree.layout(state.windows.tree, screen)

    Enum.reduce(layouts, state, fn {id, {_row, _col, width, height}}, acc ->
      EditorState.update_window(acc, id, fn window ->
        Window.resize(window, height, width)
      end)
    end)
  end

  # ── LSP lifecycle helpers ────────────────────────────────────────────────

  @spec lsp_buffer_opened(state(), pid()) :: state()
  defp lsp_buffer_opened(state, buffer_pid) do
    new_lsp = DocumentSync.on_buffer_open(state.lsp, buffer_pid)
    %{state | lsp: new_lsp}
  end

  @spec lsp_buffer_changed(state()) :: state()
  defp lsp_buffer_changed(%{buffers: %{active: nil}} = state), do: state

  defp lsp_buffer_changed(%{buffers: %{active: buf}} = state) do
    new_lsp = DocumentSync.on_buffer_change(state.lsp, buf)
    %{state | lsp: new_lsp}
  end

  @spec lsp_after_command(state(), Mode.command(), pid() | nil) :: state()
  defp lsp_after_command(state, cmd, old_buffer) do
    state
    |> lsp_after_save(cmd)
    |> lsp_after_kill(cmd, old_buffer)
  end

  @spec lsp_after_save(state(), Mode.command()) :: state()
  defp lsp_after_save(%{buffers: %{active: buf}} = state, cmd) when is_pid(buf) do
    if cmd in [
         :save,
         :force_save,
         {:execute_ex_command, {:save, []}},
         {:execute_ex_command, {:save_quit, []}}
       ] do
      # Fire after_save hooks
      path = BufferServer.file_path(buf)
      if path, do: fire_hook(:after_save, [buf, path])

      new_lsp = DocumentSync.on_buffer_save(state.lsp, buf)
      %{state | lsp: new_lsp}
    else
      state
    end
  end

  defp lsp_after_save(state, _cmd), do: state

  @spec lsp_after_kill(state(), Mode.command(), pid() | nil) :: state()
  defp lsp_after_kill(state, cmd, old_buffer)
       when cmd in [:kill_buffer, {:execute_ex_command, {:quit, []}}] and is_pid(old_buffer) do
    # The old buffer was closed — notify LSP if it changed
    if state.buffers.active != old_buffer do
      new_lsp = DocumentSync.on_buffer_close(state.lsp, old_buffer)
      %{state | lsp: new_lsp}
    else
      state
    end
  end

  defp lsp_after_kill(state, _cmd, _old_buffer), do: state

  # ── Git buffer lifecycle ───────────────────────────────────────────────

  @spec git_buffer_opened(state(), pid()) :: state()
  defp git_buffer_opened(state, buffer_pid) do
    with path when is_binary(path) <- BufferServer.file_path(buffer_pid),
         {:ok, git_root} <- Minga.Git.root_for(path) do
      start_git_buffer(state, buffer_pid, git_root, path)
    else
      _ -> state
    end
  end

  @spec start_git_buffer(state(), pid(), String.t(), String.t()) :: state()
  defp start_git_buffer(state, buffer_pid, git_root, path) do
    {content, _cursor} = BufferServer.content_and_cursor(buffer_pid)

    case DynamicSupervisor.start_child(
           Minga.Buffer.Supervisor,
           {GitBuffer, git_root: git_root, file_path: path, initial_content: content}
         ) do
      {:ok, git_pid} ->
        %{state | git_buffers: Map.put(state.git_buffers, buffer_pid, git_pid)}

      {:error, reason} ->
        Logger.warning("Failed to start git buffer: #{inspect(reason)}")
        state
    end
  end

  @spec git_buffer_changed(state()) :: state()
  defp git_buffer_changed(%{buffers: %{active: nil}} = state), do: state

  defp git_buffer_changed(%{buffers: %{active: buf}} = state) do
    case Map.get(state.git_buffers, buf) do
      nil -> state
      git_pid -> git_buffer_update(state, buf, git_pid)
    end
  end

  @spec git_buffer_update(state(), pid(), pid()) :: state()
  defp git_buffer_update(state, buf, git_pid) do
    if Process.alive?(git_pid) do
      {content, _cursor} = BufferServer.content_and_cursor(buf)
      GitBuffer.update(git_pid, content)
    end

    state
  end

  # ── Config options ──────────────────────────────────────────────────────

  alias Minga.Config.Hooks, as: ConfigHooks

  @spec fire_hook(ConfigHooks.event(), [term()]) :: :ok
  defp fire_hook(event, args) do
    ConfigHooks.run(event, args)
  catch
    :exit, _ -> :ok
  end

  @spec apply_config_options(state()) :: state()
  defp apply_config_options(state) do
    state =
      try do
        line_numbers = ConfigOptions.get(:line_numbers)
        autopair = ConfigOptions.get(:autopair)
        theme_name = ConfigOptions.get(:theme)
        theme = Minga.Theme.get!(theme_name)

        %{state | line_numbers: line_numbers, autopair_enabled: autopair, theme: theme}
      catch
        :exit, _ -> state
      end

    # Show config load error as status message
    try do
      case ConfigLoader.load_error() do
        nil -> state
        error -> %{state | status_msg: error}
      end
    catch
      :exit, _ -> state
    end
  end

  # ── Completion helpers ───────────────────────────────────────────────────────

  @arrow_up 57_352
  @arrow_down 57_353

  @spec handle_completion_key(state(), Completion.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, state()} | :passthrough

  # Escape — dismiss completion and stay in insert mode
  defp handle_completion_key(state, _completion, @escape, _mods) do
    {:handled, dismiss_completion(state)}
  end

  # C-n or arrow down — move selection down
  defp handle_completion_key(state, completion, cp, mods)
       when (cp == ?n and band(mods, @ctrl) != 0) or cp == @arrow_down do
    {:handled, %{state | completion: Completion.move_down(completion)}}
  end

  # C-p or arrow up — move selection up
  defp handle_completion_key(state, completion, cp, mods)
       when (cp == ?p and band(mods, @ctrl) != 0) or cp == @arrow_up do
    {:handled, %{state | completion: Completion.move_up(completion)}}
  end

  # Tab or Enter — accept the selected completion
  defp handle_completion_key(state, completion, cp, _mods) when cp in [@tab, @enter] do
    case Completion.accept(completion) do
      nil ->
        {:handled, dismiss_completion(state)}

      {:insert_text, text} ->
        new_state = accept_completion_text(state, completion, text)
        {:handled, dismiss_completion(new_state)}

      {:text_edit, edit} ->
        new_state = apply_completion_text_edit(state, edit)
        {:handled, dismiss_completion(new_state)}
    end
  end

  # All other keys — pass through to normal insert mode handling
  defp handle_completion_key(_state, _completion, _cp, _mods), do: :passthrough

  @spec accept_completion_text(state(), Completion.t(), String.t()) :: state()
  defp accept_completion_text(%{buffers: %{active: buf}} = state, completion, text)
       when is_pid(buf) do
    # Replace the text typed since the trigger position with the completion text
    # in a single apply_text_edit call (no N+2 round-trips).
    {trigger_line, trigger_col} = completion.trigger_position
    {_content, {cursor_line, cursor_col}} = BufferServer.content_and_cursor(buf)

    if cursor_line == trigger_line and cursor_col > trigger_col do
      BufferServer.apply_text_edit(buf, trigger_line, trigger_col, cursor_line, cursor_col, text)
    else
      BufferServer.insert_text(buf, text)
    end

    state |> lsp_buffer_changed() |> git_buffer_changed()
  end

  defp accept_completion_text(state, _completion, _text), do: state

  @spec apply_completion_text_edit(state(), Completion.text_edit()) :: state()
  defp apply_completion_text_edit(%{buffers: %{active: buf}} = state, edit) when is_pid(buf) do
    BufferServer.apply_text_edit(
      buf,
      edit.range.start_line,
      edit.range.start_col,
      edit.range.end_line,
      edit.range.end_col,
      edit.new_text
    )

    state |> lsp_buffer_changed() |> git_buffer_changed()
  end

  defp apply_completion_text_edit(state, _edit), do: state

  @spec maybe_update_completion(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_update_completion(state, codepoint, _mods) do
    buf = state.buffers.active
    if buf == nil, do: state, else: do_update_completion(state, buf, codepoint)
  end

  @spec do_update_completion(state(), pid(), non_neg_integer()) :: state()
  defp do_update_completion(state, buf, codepoint) do
    # If we have active completion, update the filter
    state = update_completion_filter(state, buf)

    # Try to trigger new completion if we just typed a character
    maybe_trigger_completion(state, buf, codepoint)
  end

  @spec update_completion_filter(state(), pid()) :: state()
  defp update_completion_filter(%{completion: nil} = state, _buf), do: state

  defp update_completion_filter(%{completion: %Completion{} = completion} = state, buf) do
    prefix = completion_prefix(buf, completion.trigger_position)
    apply_completion_filter(state, completion, prefix)
  end

  @spec apply_completion_filter(state(), Completion.t(), String.t() | nil) :: state()
  defp apply_completion_filter(state, _completion, nil), do: dismiss_completion(state)
  defp apply_completion_filter(state, _completion, ""), do: dismiss_completion(state)

  defp apply_completion_filter(state, completion, prefix) do
    filtered = Completion.filter(completion, prefix)

    if Completion.active?(filtered) do
      %{state | completion: filtered}
    else
      dismiss_completion(state)
    end
  end

  @spec maybe_trigger_completion(state(), pid(), non_neg_integer()) :: state()
  defp maybe_trigger_completion(state, buf, codepoint) do
    case codepoint_to_char(codepoint) do
      nil ->
        state

      char ->
        {new_bridge, _comp} =
          CompletionTrigger.maybe_trigger(state.completion_trigger, char, buf, state.lsp)

        %{state | completion_trigger: new_bridge}
    end
  end

  @spec dismiss_completion(state()) :: state()
  defp dismiss_completion(state) do
    new_bridge = CompletionTrigger.dismiss(state.completion_trigger)
    %{state | completion: nil, completion_trigger: new_bridge}
  end

  @spec completion_prefix(pid(), {non_neg_integer(), non_neg_integer()}) :: String.t() | nil
  defp completion_prefix(buf, {trigger_line, trigger_col}) do
    {content, {cursor_line, cursor_col}} = BufferServer.content_and_cursor(buf)

    if cursor_line == trigger_line and cursor_col >= trigger_col do
      lines = String.split(content, "\n")

      case Enum.at(lines, cursor_line) do
        nil -> nil
        line_text -> String.slice(line_text, trigger_col, cursor_col - trigger_col)
      end
    else
      nil
    end
  end

  @spec codepoint_to_char(non_neg_integer()) :: String.t() | nil
  defp codepoint_to_char(cp) when cp >= 32 and cp <= 0x10FFFF do
    <<cp::utf8>>
  rescue
    ArgumentError -> nil
  end

  defp codepoint_to_char(_), do: nil
end
