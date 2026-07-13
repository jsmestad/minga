defmodule MingaEditor.Shell.Traditional.DeactivationWorkflow do
  @moduledoc "Cancels and clears Traditional transient lifecycles before the shell is stashed."

  alias MingaEditor.Shell.Traditional.FlashesWorkflow
  alias MingaEditor.Shell.Traditional.GitToastWorkflow
  alias MingaEditor.Shell.Traditional.HoverPopupWorkflow
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.SignatureHelpWorkflow
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow

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
  end

  def run(state), do: state
end
