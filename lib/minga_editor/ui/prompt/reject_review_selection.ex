defmodule MingaEditor.UI.Prompt.RejectReviewSelection do
  @moduledoc "Confirms the exact whole units named by a visual act-menu offer."

  @behaviour MingaEditor.UI.Prompt.Handler

  alias MingaEditor.Shell.Traditional.ActMenuWorkflow
  alias MingaEditor.State

  @impl true
  @spec label() :: String.t()
  def label, do: "Reject the selected Minga changes? Your edits stay."

  @impl true
  @spec on_submit(String.t(), State.t()) :: State.t()
  def on_submit(_text, state), do: state

  @impl true
  @spec on_submit(String.t(), State.t(), map() | nil) :: State.t()
  def on_submit(_text, state, %{review: review}),
    do: ActMenuWorkflow.confirm_review_reject(state, review)

  def on_submit(text, state, _context), do: on_submit(text, state)
end
