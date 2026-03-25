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
  alias Minga.Editor.Editing
  alias Minga.Editor.MacroReplay
  alias Minga.Editor.ModeTransitions
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
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
    old_mode = Editing.mode(state)

    # Route through EditingModel.Vim, which delegates to Mode.process/3.
    # This proves the EditingModel abstraction under real load. When CUA
    # (#306) arrives, this call site dispatches through the active editing
    # model instead of hardcoding Vim.
    vim_state = VimModel.from_editor(old_mode, Editing.mode_state(state))
    {new_mode, commands, new_vim_state} = VimModel.process_key(vim_state, key)
    {_, new_mode_state} = VimModel.to_editor(new_vim_state)

    # Record keys for dot repeat, unless we're currently replaying.
    state = ChangeTracking.maybe_record_change(state, old_mode, new_mode, commands, key)

    # Record keys into macro register if actively recording (and not replaying).
    state = MacroReplay.maybe_record_key(state, key, commands)

    # Guard: block mutating mode transitions on read-only buffers.
    # Covers insert, replace, and operator-pending for mutating operators
    # (delete, change, indent, dedent, reindent, comment). Yank is allowed
    # because it doesn't modify the buffer.
    {new_mode, commands, new_mode_state, state} =
      guard_read_only(new_mode, commands, new_mode_state, state)

    # When transitioning INTO visual or command mode, adjust mode_state.
    new_mode_state =
      ModeTransitions.adjust(new_mode_state, old_mode, new_mode, state)

    # Stamp the active buffer's filetype onto mode state so mode modules
    # can resolve filetype-scoped bindings without a side-channel lookup.
    new_mode_state = set_mode_filetype(new_mode_state, state)

    base_state = EditorState.transition_mode(state, new_mode, new_mode_state)

    # Fire mode change hook and break undo coalescing.
    if old_mode != new_mode do
      if base_state.workspace.buffers.active,
        do: BufferServer.break_undo_coalescing(base_state.workspace.buffers.active)

      Minga.Events.broadcast(:mode_changed, %Minga.Events.ModeEvent{old: old_mode, new: new_mode})
    end

    after_commands =
      Enum.reduce(commands, base_state, fn cmd, acc ->
        dispatch_command(acc, cmd)
      end)

    # Clean up mode_state if we've transitioned back to Normal.
    # Skip if a command changed the mode (e.g. substitute confirm, search).
    result =
      if new_mode == :normal and old_mode != :normal and Editing.mode(after_commands) == :normal do
        case Editing.mode_state(after_commands) do
          %Mode.State{} -> after_commands
          _ -> Editing.update_mode_state(after_commands, fn _ -> Mode.initial_state() end)
        end
      else
        after_commands
      end

    # When leaving :tool_confirm, check if more tools were queued during
    # the session and re-enter :tool_confirm to prompt for them.
    if old_mode == :tool_confirm and Editing.mode(result) == :normal and
         result.tool_prompt_queue != [] do
      ms = %Minga.Mode.ToolConfirmState{
        pending: result.tool_prompt_queue,
        declined: result.tool_declined
      }

      EditorState.transition_mode(result, :tool_confirm, ms)
    else
      result
    end
  end

  @doc """
  Dispatches a single command through the command registry and advice system.
  """
  @spec dispatch_command(EditorState.t(), Mode.command()) :: EditorState.t()
  def dispatch_command(state, cmd) do
    old_buffer = state.workspace.buffers.active
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
  # Prefers the active window's buffer over state.workspace.buffers.active, since popup
  # windows may display a different buffer than the one tracked in the
  # buffers struct.
  @spec active_buffer_read_only?(EditorState.t()) :: boolean()
  defp active_buffer_read_only?(state) do
    # When the agent input is focused, the target buffer is the prompt
    # buffer (which is writable), not the read-only chat buffer.
    if AgentAccess.input_focused?(state) do
      false
    else
      check_window_buffer_read_only(state)
    end
  end

  @spec check_window_buffer_read_only(EditorState.t()) :: boolean()
  defp check_window_buffer_read_only(
         %{workspace: %{windows: %{map: map, active: active_id}}} = state
       ) do
    buf =
      case Map.fetch(map, active_id) do
        {:ok, window} -> window.buffer
        :error -> state.workspace.buffers.active
      end

    buf != nil and BufferServer.read_only?(buf)
  catch
    :exit, _ -> false
  end

  # ── Read-only guard for mode transitions ──────────────────────────────────

  @read_only_msg "Buffer is read-only"

  @spec guard_read_only(Mode.mode(), [Mode.command()], Mode.state(), EditorState.t()) ::
          {Mode.mode(), [Mode.command()], Mode.state(), EditorState.t()}
  defp guard_read_only(mode, commands, mode_state, state)
       when mode in [:insert, :replace] do
    if active_buffer_read_only?(state) do
      {:normal, [], Mode.initial_state(), EditorState.set_status(state, @read_only_msg)}
    else
      {mode, commands, mode_state, state}
    end
  end

  defp guard_read_only(:operator_pending, commands, mode_state, state) do
    if mutating_operator?(mode_state) and active_buffer_read_only?(state) do
      {:normal, [], Mode.initial_state(), EditorState.set_status(state, @read_only_msg)}
    else
      {:operator_pending, commands, mode_state, state}
    end
  end

  defp guard_read_only(mode, commands, mode_state, state) do
    {mode, commands, mode_state, state}
  end

  @mutating_operators [:delete, :change, :indent, :dedent, :reindent, :comment]

  @spec mutating_operator?(Mode.state()) :: boolean()
  defp mutating_operator?(%Minga.Mode.OperatorPendingState{operator: op}),
    do: op in @mutating_operators

  defp mutating_operator?(_), do: false

  # ── Filetype stamping ──────────────────────────────────────────────────────

  @spec set_mode_filetype(Mode.state(), EditorState.t()) :: Mode.state()
  defp set_mode_filetype(%{filetype: _} = mode_state, state) do
    filetype = active_filetype(state)
    %{mode_state | filetype: filetype}
  end

  defp set_mode_filetype(mode_state, _state), do: mode_state

  @spec active_filetype(EditorState.t()) :: atom()
  defp active_filetype(%{workspace: %{buffers: %{active: nil}}}), do: :text

  defp active_filetype(%{workspace: %{buffers: %{active: buf}}}) do
    BufferServer.filetype(buf)
  catch
    :exit, _ -> :text
  end
end
