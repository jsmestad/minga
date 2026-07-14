defmodule MingaEditor.Shell.Traditional.DeactivationWorkflow do
  @moduledoc "Cancels and clears Traditional transient lifecycles before the shell is stashed."

  alias MingaEditor.Input.CUA.TUISpaceLeader
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.FlashesWorkflow
  alias MingaEditor.Shell.Traditional.GitToastWorkflow
  alias MingaEditor.Shell.Traditional.HoverPopupWorkflow
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Shell.Traditional.SignatureHelpWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow
  alias MingaEditor.State, as: EditorState

  @doc "Ends transient Traditional presentation before another shell becomes active."
  @spec run(map()) :: map()
  def run(%{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state) do
    state
    |> NoticeWorkflow.dismiss()
    |> FlashesWorkflow.cancel_nav()
    |> FlashesWorkflow.cancel_yank()
    |> GitToastWorkflow.dismiss()
    |> WhichKeyWorkflow.dismiss()
    |> HoverPopupWorkflow.dismiss()
    |> SignatureHelpWorkflow.dismiss()
    |> ModalWorkflow.dismiss()
    |> SidebarWorkflow.close_observatory()
    |> TUISpaceLeader.cancel()
    |> reset_click_regions()
  end

  def run(state), do: state

  @spec reset_click_regions(EditorState.t()) :: EditorState.t()
  defp reset_click_regions(%EditorState{} = state) do
    shell_state = state.shell_runtime |> Runtime.state() |> TraditionalState.reset_click_regions()

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end
end
