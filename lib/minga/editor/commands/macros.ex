defmodule Minga.Editor.Commands.Macros do
  @moduledoc """
  Macro recording and replay commands.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State, as: EditorState

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Action the GenServer must dispatch after execute."
  @type action :: {:replay_macro, String.t()}

  @spec toggle_recording(state()) :: state()
  def toggle_recording(state) do
    case MacroRecorder.recording?(state.workspace.vim.macro_recorder) do
      {true, _reg} ->
        rec = MacroRecorder.stop_recording(state.workspace.vim.macro_recorder)
        %{state | workspace: %{state.workspace | vim: %{state.workspace.vim | macro_recorder: rec}}, status_msg: "Recorded macro"}

      false ->
        Minga.Editor.State.update_workspace(state, fn ws ->
          %{
            ws
            | vim: %{
                ws.vim
                | mode_state: %{ws.vim.mode_state | pending_macro_register: true}
              }
          }
        end)
    end
  end

  @spec replay_last(state()) :: state() | {state(), action()}
  def replay_last(%EditorState{workspace: %{vim: %{macro_recorder: %{last_register: nil}}}} = state) do
    %{state | status_msg: "No previous macro"}
  end

  def replay_last(%EditorState{workspace: %{vim: %{macro_recorder: %{last_register: reg}}}} = state) do
    {state, {:replay_macro, reg}}
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
