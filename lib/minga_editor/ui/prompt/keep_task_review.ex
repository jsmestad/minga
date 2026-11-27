defmodule MingaEditor.UI.Prompt.KeepTaskReview do
  @moduledoc "Confirms the exact set of file offers presented by the task review."

  @behaviour MingaEditor.UI.Prompt.Handler

  alias MingaEditor.Shell.Traditional.TaskReviewWorkflow
  alias MingaEditor.State

  @impl true
  @spec label() :: String.t()
  def label, do: "Keep all pending changes?"

  @impl true
  @spec on_submit(String.t(), State.t()) :: State.t()
  def on_submit(_text, state), do: state

  @impl true
  @spec on_submit(String.t(), State.t(), map() | nil) :: State.t()
  def on_submit(_text, state, %{tab: _, review: _, pane: _} = context),
    do: TaskReviewWorkflow.keep_confirmed(state, context)

  def on_submit(text, state, _context), do: on_submit(text, state)
end
