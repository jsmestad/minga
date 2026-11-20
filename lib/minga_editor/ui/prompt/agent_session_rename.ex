defmodule MingaEditor.UI.Prompt.AgentSessionRename do
  @moduledoc "Renames the saved conversation selected when the shared prompt opened."

  @behaviour MingaEditor.UI.Prompt.Handler

  alias MingaEditor.Agent.SessionOrganization
  alias MingaEditor.PromptUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State

  @spec open(State.t()) :: State.t()
  def open(state) do
    case SessionOrganization.origin(state) do
      nil -> NoticeWorkflow.publish(state, "Open a saved local Agent session to rename it.")
      origin -> PromptUI.open(state, __MODULE__, context: origin)
    end
  end

  @impl true
  @spec label() :: String.t()
  def label, do: "Rename Agent session: "

  @impl true
  @spec on_submit(String.t(), State.t()) :: State.t()
  def on_submit(title, state), do: on_submit(title, state, nil)

  @impl true
  @spec on_submit(String.t(), State.t(), SessionOrganization.origin() | nil) :: State.t()
  def on_submit(title, state, %{target: _target} = displayed) do
    if SessionOrganization.origin(state) == displayed,
      do: SessionOrganization.start(state, displayed, {:rename, title}),
      else: on_submit(title, state, nil)
  end

  def on_submit(_title, state, nil),
    do: NoticeWorkflow.publish(state, "Session changed. Reopen Rename Agent session.")
end
