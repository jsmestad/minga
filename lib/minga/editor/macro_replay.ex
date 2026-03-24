defmodule Minga.Editor.MacroReplay do
  @moduledoc """
  Macro recording and replay helpers for the Editor.

  Manages the `MacroRecorder` state during key presses and handles
  macro replay by feeding recorded keys back through the Editor's
  key dispatch.
  """

  alias Minga.Editor.Editing
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
  def maybe_record_key(state, key, commands) do
    rec = Editing.macro_recorder(state)

    if rec.replaying do
      state
    else
      case MacroRecorder.recording?(rec) do
        {true, _reg} ->
          has_stop? = Enum.any?(commands, &match?(:toggle_macro_recording, &1))

          if has_stop? do
            state
          else
            Editing.set_macro_recorder(state, MacroRecorder.record_key(rec, key))
          end

        false ->
          state
      end
    end
  end

  @doc """
  Replays a macro from the given register.

  Feeds each recorded key back through `Editor.do_handle_key/3`
  with recording suppressed to avoid overwriting the macro.
  """
  @spec replay(state(), String.t()) :: state()
  def replay(state, register) do
    rec = Editing.macro_recorder(state)

    case MacroRecorder.get_macro(rec, register) do
      nil ->
        state

      keys ->
        rec = MacroRecorder.start_replay(rec)
        state = Editing.set_macro_recorder(state, rec)

        state =
          Enum.reduce(keys, state, fn {codepoint, modifiers}, acc ->
            Minga.Editor.do_handle_key(acc, codepoint, modifiers)
          end)

        rec = MacroRecorder.stop_replay(Editing.macro_recorder(state))
        Editing.set_macro_recorder(state, rec)
    end
  end
end
