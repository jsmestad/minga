defmodule Minga.Editor.ChangeTracking do
  @moduledoc """
  Change recording and dot-repeat helpers for the Editor.

  Manages the `ChangeRecorder` state during mode transitions and key
  presses. Also handles dot-repeat replay by feeding recorded keys
  back through the Editor's key dispatch.

  All functions are pure state transformations except `replay_last_change`,
  which calls back into `Editor.do_handle_key/3` for replay.
  """

  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @doc """
  Records a key press for dot repeat, unless currently replaying.
  """
  @spec maybe_record_change(
          state(),
          Mode.mode(),
          Mode.mode(),
          [Mode.command()],
          {non_neg_integer(), non_neg_integer()}
        ) :: state()
  def maybe_record_change(%EditorState{workspace: %{vim: %{change_recorder: %{replaying: true}}}} = state, _, _, _, _),
    do: state

  def maybe_record_change(
        %EditorState{workspace: %{vim: %{change_recorder: rec} = vim}} = state,
        old_mode,
        new_mode,
        commands,
        key
      ) do
    rec = update_recorder(rec, old_mode, new_mode, commands, key)
    %{state | workspace: %{state.workspace | vim: %{vim | change_recorder: rec}}}
  end

  @doc """
  Replays the last recorded change, optionally with a new count.

  Feeds each recorded key back through `Editor.do_handle_key/3`
  with recording suppressed to avoid overwriting the stored change.
  """
  @spec replay_last_change(state(), non_neg_integer() | nil) :: state()
  def replay_last_change(%EditorState{workspace: %{vim: %{change_recorder: rec}}} = state, count) do
    case ChangeRecorder.get_last_change(rec) do
      nil ->
        state

      keys ->
        keys = ChangeRecorder.replace_count(keys, count)

        rec = ChangeRecorder.start_replay(rec)
        state = %{state | workspace: %{state.workspace | vim: %{state.workspace.vim | change_recorder: rec}}}

        state =
          Enum.reduce(keys, state, fn {codepoint, modifiers}, acc ->
            Minga.Editor.do_handle_key(acc, codepoint, modifiers)
          end)

        rec = ChangeRecorder.stop_replay(state.workspace.vim.change_recorder)
        %{state | workspace: %{state.workspace | vim: %{state.workspace.vim | change_recorder: rec}}}
    end
  end

  # ── Recorder state machine ──────────────────────────────────────────────

  # Already recording: record key and check for change end.
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

  # From Normal: mode transition starts recording.
  defp update_recorder(rec, :normal, new_mode, _commands, key)
       when new_mode in [:insert, :replace, :operator_pending] do
    rec |> ChangeRecorder.start_recording() |> ChangeRecorder.record_key(key)
  end

  # From Normal: single-key edit stays in Normal.
  defp update_recorder(rec, :normal, :normal, commands, key) do
    do_update_normal_to_normal(rec, commands, key)
  end

  # From OperatorPending: record and handle completion.
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

  # All other mode transitions: no recording changes.
  defp update_recorder(rec, _old_mode, _new_mode, _commands, _key), do: rec

  # Handle Normal → Normal: detect edits, pending keys, or motions.
  @spec do_update_normal_to_normal(ChangeRecorder.t(), [Mode.command()], ChangeRecorder.key()) ::
          ChangeRecorder.t()
  defp do_update_normal_to_normal(rec, [], key) do
    ChangeRecorder.buffer_pending_key(rec, key)
  end

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
  defp editing_command?({:delete_chars_at, _}), do: true
  defp editing_command?({:delete_chars_before, _}), do: true
  defp editing_command?(:delete_line), do: true
  defp editing_command?({:delete_lines_counted, _}), do: true
  defp editing_command?(:change_line), do: true
  defp editing_command?({:change_lines_counted, _}), do: true
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
end
