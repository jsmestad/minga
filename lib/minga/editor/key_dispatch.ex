defmodule Minga.Editor.KeyDispatch do
  @moduledoc """
  Core key dispatch logic for the editor.

  Routes key presses through the Mode FSM, records changes for dot repeat
  and macros, guards read-only buffers, adjusts mode transitions, fires
  hooks, and dispatches resulting commands.

  Extracted from `Minga.Editor` to reduce GenServer module size.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Advice, as: ConfigAdvice

  alias Minga.EditingModel.Vim, as: VimModel
  alias Minga.Editor.BufferLifecycle
  alias Minga.Editor.ChangeTracking
  alias Minga.Editor.Commands
  alias Minga.Editor.MacroReplay
  alias Minga.Editor.ModeTransitions
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  @doc """
  Processes a key press through the Mode FSM and dispatches commands.

  This is the central key handling function called by `Input.ModeFSM`.
  It runs the key through `Mode.process/3`, records for dot repeat and
  macros, guards read-only transitions, adjusts mode state, and runs
  all resulting commands.
  """
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  def handle_key(state, codepoint, modifiers) do
    key = {codepoint, modifiers}
    old_mode = state.vim.mode

    # Route through EditingModel.Vim, which delegates to Mode.process/3.
    # This proves the EditingModel abstraction under real load. When CUA
    # (#306) arrives, this call site dispatches through the active editing
    # model instead of hardcoding Vim.
    vim_state = VimModel.from_editor(old_mode, state.vim.mode_state)
    {new_mode, commands, new_vim_state} = VimModel.process_key(vim_state, key)
    {_, new_mode_state} = VimModel.to_editor(new_vim_state)

    # Record keys for dot repeat, unless we're currently replaying.
    state = ChangeTracking.maybe_record_change(state, old_mode, new_mode, commands, key)

    # Record keys into macro register if actively recording (and not replaying).
    state = MacroReplay.maybe_record_key(state, key, commands)

    # Guard: block insert/replace transitions on read-only buffers.
    # Check the active window's buffer (which may differ from state.buffers.active
    # when a popup window is focused).
    {new_mode, commands, new_mode_state, state} =
      if new_mode in [:insert, :replace] and active_buffer_read_only?(state) do
        {:normal, [], Mode.initial_state(), %{state | status_msg: "Buffer is read-only"}}
      else
        {new_mode, commands, new_mode_state, state}
      end

    # When transitioning INTO visual or command mode, adjust mode_state.
    new_mode_state =
      ModeTransitions.adjust(new_mode_state, old_mode, new_mode, state)

    base_state = %{state | vim: %{state.vim | mode: new_mode, mode_state: new_mode_state}}

    # Fire mode change hook and break undo coalescing.
    if old_mode != new_mode do
      if base_state.buffers.active,
        do: BufferServer.break_undo_coalescing(base_state.buffers.active)

      Minga.Events.broadcast(:mode_changed, %Minga.Events.ModeEvent{old: old_mode, new: new_mode})
    end

    after_commands =
      Enum.reduce(commands, base_state, fn cmd, acc ->
        dispatch_command(acc, cmd)
      end)

    # Clean up mode_state if we've transitioned back to Normal.
    # Skip if a command changed the mode (e.g. substitute confirm, search).
    if new_mode == :normal and old_mode != :normal and after_commands.vim.mode == :normal do
      case after_commands.vim.mode_state do
        %Mode.State{} -> after_commands
        _ -> %{after_commands | vim: %{after_commands.vim | mode_state: Mode.initial_state()}}
      end
    else
      after_commands
    end
  end

  @doc """
  Dispatches a single command through the command registry and advice system.
  """
  @spec dispatch_command(EditorState.t(), Mode.command()) :: EditorState.t()
  def dispatch_command(state, cmd) do
    old_buffer = state.buffers.active
    cmd_name = command_name(cmd)

    execute = fn s ->
      case Commands.execute(s, cmd) do
        {s2, {:dot_repeat, count}} -> ChangeTracking.replay_last_change(s2, count)
        {s2, {:replay_macro, register}} -> MacroReplay.replay(s2, register)
        {s2, {:whichkey_update, wk}} -> %{s2 | whichkey: wk}
        s2 -> s2
      end
    end

    result = ConfigAdvice.wrap(cmd_name, execute).(state)

    BufferLifecycle.lsp_after_command(result, cmd, old_buffer)
  end

  @spec command_name(Mode.command()) :: atom()
  defp command_name(cmd) when is_atom(cmd), do: cmd
  defp command_name(cmd) when is_tuple(cmd), do: elem(cmd, 0)
  defp command_name(cmd) when is_list(cmd), do: :multi
  defp command_name(_cmd), do: :unknown

  # Checks whether the buffer in the active window is read-only.
  # Prefers the active window's buffer over state.buffers.active, since popup
  # windows may display a different buffer than the one tracked in the
  # buffers struct.
  @spec active_buffer_read_only?(EditorState.t()) :: boolean()
  defp active_buffer_read_only?(%{windows: %{map: map, active: active_id}} = state) do
    buf =
      case Map.fetch(map, active_id) do
        {:ok, window} -> window.buffer
        :error -> state.buffers.active
      end

    buf != nil and BufferServer.read_only?(buf)
  catch
    :exit, _ -> false
  end
end
