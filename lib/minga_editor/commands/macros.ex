defmodule MingaEditor.Commands.Macros do
  @moduledoc """
  Macro recording and replay commands.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.Editing
  alias MingaEditor.MacroRecorder
  alias MingaEditor.State, as: EditorState

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Action the GenServer must dispatch after execute."
  @type action :: {:replay_macro, String.t()}

  @spec toggle_recording(state()) :: state()
  def toggle_recording(state) do
    case Editing.macro_recording?(state) do
      {true, _reg} ->
        rec = MacroRecorder.stop_recording(Editing.macro_recorder(state))
        state = Editing.set_macro_recorder(state, rec)
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Recorded macro")

      false ->
        Editing.update_mode_state(state, fn ms ->
          %{ms | pending: :macro_register}
        end)
    end
  end

  @spec replay_last(state()) :: state() | {state(), action()}
  def replay_last(state) do
    rec = Editing.macro_recorder(state)

    case MacroRecorder.last_register(rec) do
      nil ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No previous macro")

      reg ->
        {state, {:replay_macro, reg}}
    end
  end

  command(:toggle_macro_recording, "Toggle macro recording",
    requires_buffer: true,
    execute: &toggle_recording/1
  )

  command(:replay_last_macro, "Replay last macro",
    requires_buffer: true,
    execute: &replay_last/1
  )
end
