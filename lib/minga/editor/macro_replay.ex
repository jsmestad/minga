defmodule Minga.Editor.MacroReplay do
  @moduledoc """
  Macro recording and replay helpers for the Editor.

  Manages the `MacroRecorder` state during key presses and handles
  macro replay by feeding recorded keys back through the Editor's
  key dispatch.
  """

  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @doc """
  Records a key press into the active macro register, unless replaying.

  Skips the `q` key that stops recording to avoid including it in
  the recorded macro.
  """
  @spec maybe_record_key(
          state(),
          {non_neg_integer(), non_neg_integer()},
          [Mode.command()]
        ) :: state()
  def maybe_record_key(%{macro_recorder: %{replaying: true}} = state, _key, _cmds), do: state

  def maybe_record_key(%{macro_recorder: rec} = state, key, commands) do
    case MacroRecorder.recording?(rec) do
      {true, _reg} ->
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

  @doc """
  Replays a macro from the given register.

  Feeds each recorded key back through `Editor.do_handle_key/3`
  with recording suppressed to avoid overwriting the macro.
  """
  @spec replay(state(), String.t()) :: state()
  def replay(%{macro_recorder: rec} = state, register) do
    case MacroRecorder.get_macro(rec, register) do
      nil ->
        state

      keys ->
        rec = MacroRecorder.start_replay(rec)
        state = %{state | macro_recorder: rec}

        state =
          Enum.reduce(keys, state, fn {codepoint, modifiers}, acc ->
            Minga.Editor.do_handle_key(acc, codepoint, modifiers)
          end)

        rec = MacroRecorder.stop_replay(state.macro_recorder)
        %{state | macro_recorder: rec}
    end
  end
end
