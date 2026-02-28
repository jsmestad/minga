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

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.Commands
  alias Minga.Editor.Mouse
  alias Minga.Editor.PickerUI
  alias Minga.Editor.Renderer
  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.Mode.CommandState
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol

  require Logger

  import Bitwise

  @ctrl Protocol.mod_ctrl()

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

  # ── Server Callbacks ─────────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    port_manager = Keyword.get(opts, :port_manager, PortManager)
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

    buffers = if buffer, do: [buffer], else: []

    state = %EditorState{
      buffer: buffer,
      buffers: buffers,
      active_buffer: 0,
      port_manager: port_manager,
      viewport: Viewport.new(height, width),
      mode: :normal,
      mode_state: Mode.initial_state()
    }

    {:ok, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:open_file, file_path}, _from, state) do
    case Commands.start_buffer(file_path) do
      {:ok, pid} ->
        new_state = Commands.add_buffer(state, pid)
        Renderer.render(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast(:render, state) do
    Renderer.render(state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:minga_input, {:ready, width, height}}, state) do
    new_state = %{state | viewport: Viewport.new(height, width)}
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:resize, width, height}}, state) do
    new_state = %{state | viewport: Viewport.new(height, width)}
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:key_press, codepoint, modifiers}}, %{picker: picker} = state)
      when is_struct(picker, Minga.Picker) do
    new_state =
      case PickerUI.handle_key(state, codepoint, modifiers) do
        {s, {:execute_command, cmd}} -> dispatch_command(s, cmd)
        s -> s
      end

    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:key_press, codepoint, modifiers}}, state) do
    new_state = handle_key(state, codepoint, modifiers)
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:mouse_event, row, col, button, _mods, event_type}}, state) do
    new_state = Mouse.handle(state, row, col, button, event_type)
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:whichkey_timeout, ref}, %{whichkey_timer: ref} = state) do
    new_state = %{state | show_whichkey: true}
    Renderer.render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:whichkey_timeout, _ref}, state) do
    # Stale timer — ignore.
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Key dispatch ─────────────────────────────────────────────────────────────

  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: state()

  # Global bindings — processed before the Mode FSM.
  # Ctrl+S → save (works in any mode).
  defp handle_key(state, ?s, mods) when band(mods, @ctrl) != 0 do
    if state.buffer do
      case BufferServer.save(state.buffer) do
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

    # When transitioning INTO visual or command mode, adjust mode_state.
    new_mode_state =
      adjust_mode_state_on_transition(new_mode_state, old_mode, new_mode, state)

    base_state = %{state | mode: new_mode, mode_state: new_mode_state}

    # Clear any stale leader update from the process dictionary.
    Process.delete(:__leader_update__)

    after_commands =
      Enum.reduce(commands, base_state, fn cmd, acc ->
        dispatch_command(acc, cmd)
      end)

    # After commands have executed (they may need the old mode_state, e.g.
    # VisualState for delete_visual_selection), clean up the mode_state
    # if we've transitioned back to Normal from a different mode.
    after_commands =
      if new_mode == :normal and old_mode != :normal do
        case after_commands.mode_state do
          %Mode.State{} -> after_commands
          _ -> %{after_commands | mode_state: Mode.initial_state()}
        end
      else
        after_commands
      end

    # Apply any leader/whichkey state updates emitted by execute_command.
    case Process.delete(:__leader_update__) do
      nil ->
        after_commands

      updates ->
        Map.merge(after_commands, updates)
    end
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
  defp adjust_mode_state_on_transition(mode_state, old_mode, :visual, %{buffer: buf})
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

  # Dispatches a command through Commands.execute/2, handling action tuples.
  @spec dispatch_command(state(), Mode.command()) :: state()
  defp dispatch_command(state, cmd) do
    case Commands.execute(state, cmd) do
      {s, {:dot_repeat, count}} -> replay_last_change(s, count)
      s -> s
    end
  end
end
