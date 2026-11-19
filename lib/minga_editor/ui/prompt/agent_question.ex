defmodule MingaEditor.UI.Prompt.AgentQuestion do
  @moduledoc "Collects a free-text answer to one displayed Agent question."

  @behaviour MingaEditor.UI.Prompt.Handler

  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.UI.Picker.AgentQuestionSource

  @impl true
  @spec label() :: String.t()
  def label, do: "Answer Agent question"

  @impl true
  @spec on_submit(String.t(), State.t()) :: State.t()
  def on_submit(_text, state),
    do: NoticeWorkflow.publish(state, "That Agent question is no longer available.")

  @impl true
  @spec on_submit(String.t(), State.t(), map() | nil) :: State.t()
  def on_submit(text, state, %{offer: offer}),
    do: AgentQuestionSource.submit(state, offer, {:text, text})

  def on_submit(text, state, _context), do: on_submit(text, state)
end
