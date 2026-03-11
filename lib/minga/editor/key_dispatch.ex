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
  alias Minga.Config.Hooks, as: ConfigHooks
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
    old_mode = state.mode
    {new_mode, commands, new_mode_state} = Mode.process(old_mode, key, state.mode_state)

    # Record keys for dot repeat, unless we're currently replaying.
    state = ChangeTracking.maybe_record_change(state, old_mode, new_mode, commands, key)

    # Record keys into macro register if actively recording (and not replaying).
    state = MacroReplay.maybe_record_key(state, key, commands)

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
      ModeTransitions.adjust(new_mode_state, old_mode, new_mode, state)

    base_state = %{state | mode: new_mode, mode_state: new_mode_state}

    # Fire mode change hook and break undo coalescing.
    if old_mode != new_mode do
      if base_state.buffers.active,
        do: BufferServer.break_undo_coalescing(base_state.buffers.active)

      fire_hook(:on_mode_change, [old_mode, new_mode])
    end

    after_commands =
      Enum.reduce(commands, base_state, fn cmd, acc ->
        dispatch_command(acc, cmd)
      end)

    # Clean up mode_state if we've transitioned back to Normal.
    # Skip if a command changed the mode (e.g. substitute confirm, search).
    if new_mode == :normal and old_mode != :normal and after_commands.mode == :normal do
      case after_commands.mode_state do
        %Mode.State{} -> after_commands
        _ -> %{after_commands | mode_state: Mode.initial_state()}
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

  @spec fire_hook(ConfigHooks.event(), [term()]) :: :ok
  defp fire_hook(event, args) do
    ConfigHooks.run(event, args)
  catch
    :exit, _ -> :ok
  end
end
