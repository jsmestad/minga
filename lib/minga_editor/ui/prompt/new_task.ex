defmodule MingaEditor.UI.Prompt.NewTask do
  @moduledoc """
  The "New task ›" prompt, opened with `c` in the tasks drawer.

  The goal you type becomes the task's title and its first prompt. The task starts in a session of its own beside the conversation in front, and the drawer selects it, so starting a task never takes you away from what you were doing. `esc` cancels and leaves the drawer as it was.

  The task runs on the model of the conversation in front when it has one, so a model picked there carries over; otherwise it runs on the configured default.
  """

  @behaviour MingaEditor.UI.Prompt.Handler

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  @impl true
  @spec label() :: String.t()
  def label, do: "New task › "

  @impl true
  @spec on_submit(String.t(), map()) :: map()
  def on_submit(text, state) do
    case String.trim(text) do
      "" ->
        NoticeWorkflow.publish(state, "A task needs a goal: type what Minga should do")

      goal ->
        id = make_ref()
        {state, row} = MingaEditor.Agent.TaskWorkflow.start(state, id, goal)

        state
        |> MingaEditor.Shell.Traditional.TasksDrawerWorkflow.select_row(row)
        |> AgentSession.start_agent_session(
          background: true,
          recover_interrupted_work?: false,
          follow_up: {:prompt, goal, id},
          model: UIState.model_selection(state.workspace.agent_ui)
        )
    end
  end
end
