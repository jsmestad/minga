defmodule Minga.Editor.Commands.Macros do
  @moduledoc """
  Macro recording and replay commands.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Editor.Editing
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State, as: EditorState

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
        EditorState.set_status(state, "Recorded macro")

      false ->
        Editing.update_mode_state(state, fn ms ->
          %{ms | pending: :macro_register}
        end)
    end
  end

  @spec replay_last(state()) :: state() | {state(), action()}
  def replay_last(state) do
    case Editing.macro_recorder(state) do
      %{last_register: nil} ->
        EditorState.set_status(state, "No previous macro")

      %{last_register: reg} ->
        {state, {:replay_macro, reg}}
    end
  end

  @impl Minga.Command.Provider
  def __commands__ do
    [
      %Minga.Command{
        name: :toggle_macro_recording,
        description: "Toggle macro recording",
        requires_buffer: true,
        execute: &toggle_recording/1
      },
      %Minga.Command{
        name: :replay_last_macro,
        description: "Replay last macro",
        requires_buffer: true,
        execute: &replay_last/1
      }
    ]
  end
end
