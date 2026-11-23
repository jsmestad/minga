defmodule MingaEditor.RenderModel.UI.AgentContextBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.AgentContext
  alias Minga.RenderModel.UI.AgentContext.Progress
  alias Minga.RenderModel.UI.AgentContext.Todo
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.PendingQuestion
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.WorkspaceStatus
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace

  @spec build(Context.t() | term()) :: AgentContext.t()
  def build(%Context{workspace: %{agent_ui: %{chat_lifecycle: :unavailable}}}), do: hidden()

  def build(%Context{} = ctx) do
    activity = get_activity(ctx)
    status = status(ctx)
    action = action(ctx, activity)

    if visible?(activity, status) do
      %AgentContext{
        visible: true,
        task: card_task(ctx, activity, status, action),
        dispatch_timestamp: activity.started_at,
        status: status,
        can_approve: false,
        todos: todos(activity),
        progress: progress(activity, action)
      }
    else
      hidden()
    end
  end

  def build(_other), do: hidden()

  @spec visible?(Context.t() | map()) :: boolean()
  def visible?(%{workspace: %{agent_ui: %{chat_lifecycle: :unavailable}}}), do: false

  def visible?(%Context{} = ctx), do: visible?(get_activity(ctx), status(ctx))

  def visible?(%{workspace: %{agent_ui: %UIState{} = ui}} = state) do
    visible?(ui.view.activity, workspace_status(shell_state(state), ui))
  end

  @spec hidden() :: AgentContext.t()
  defp hidden do
    %AgentContext{visible: false}
  end

  @spec get_activity(Context.t()) :: Activity.t()
  defp get_activity(%Context{
         workspace: %{agent_ui: %{view: %{activity: %Activity{} = activity}}}
       }),
       do: activity

  defp get_activity(_ctx), do: Activity.new()

  @spec shell_state(map()) :: TraditionalState.t() | nil
  defp shell_state(%MingaEditor.RenderPipeline.Input{
         intent: %{frame: %{shell_state: %TraditionalState{} = shell_state}}
       }),
       do: shell_state

  defp shell_state(%{shell_runtime: %{state: %TraditionalState{} = shell_state}}), do: shell_state
  defp shell_state(_state), do: nil

  # The strip shows the same workspace status as the workspace pill; only the
  # mapping to the card's status enum is local.
  @spec status(Context.t()) :: AgentContext.status()
  defp status(%Context{intent: %{frame: %{shell_state: shell_state}}} = ctx),
    do: workspace_status(shell_state, ctx.workspace.agent_ui)

  @spec workspace_status(term(), UIState.t() | nil) :: AgentContext.status()
  defp workspace_status(shell_state, ui) do
    shell_state
    |> active_workspace()
    |> WorkspaceStatus.resolve(WorkspaceStatus.live_agent(shell_state), ui)
    |> context_status()
  end

  @spec active_workspace(term()) :: Workspace.t() | nil
  defp active_workspace(%TraditionalState{} = shell_state) do
    case TraditionalState.tab_bar(shell_state) do
      %TabBar{} = tab_bar -> TabBar.active_workspace(tab_bar)
      nil -> nil
    end
  end

  defp active_workspace(_shell_state), do: nil

  # A failed start explains its cause; a pending question asks for an answer.
  @spec action(Context.t(), Activity.t()) :: String.t() | nil
  defp action(%Context{workspace: %{agent_ui: %{chat_lifecycle: {:failed, failure}}}}, _activity),
    do: failure.message

  defp action(%Context{intent: %{frame: %{shell_state: shell_state}}}, activity) do
    case WorkspaceStatus.live_agent(shell_state) do
      %AgentState{pending_question: %PendingQuestion{}} ->
        "Waiting for your answer"

      %AgentState{pending_approval: approval} ->
        active_action(activity, PendingApproval.public(approval))

      nil ->
        active_action(activity, nil)
    end
  end

  # A failed start titles the card with its headline; the cause sentence is the
  # card's action, so the two never repeat each other.
  @spec card_task(Context.t(), Activity.t(), AgentContext.status(), String.t() | nil) ::
          String.t()
  defp card_task(
         %Context{workspace: %{agent_ui: %{chat_lifecycle: {:failed, failure}}}},
         _activity,
         _status,
         _action
       ),
       do: start_failure_headline(failure)

  defp card_task(_ctx, activity, status, action), do: task(activity, status, action)

  @spec start_failure_headline(StartFailure.t()) :: String.t()
  defp start_failure_headline(%StartFailure{remedy: :set_up_provider}), do: "Agent needs setup"
  defp start_failure_headline(%StartFailure{remedy: nil}), do: "Agent unavailable"
  defp start_failure_headline(%StartFailure{}), do: "Agent could not start"

  @spec visible?(Activity.t(), AgentContext.status()) :: boolean()
  defp visible?(%Activity{}, status) when status in [:needs_you, :working, :iterating, :errored],
    do: true

  defp visible?(%Activity{todos: todos} = activity, _status) do
    todos != [] or activity.tool_count > 0 or Activity.file_count(activity) > 0
  end

  @spec task(Activity.t(), AgentContext.status(), String.t() | nil) :: String.t()
  defp task(_activity, _status, action) when action not in ["", nil], do: action

  defp task(%Activity{todos: [%{description: description} | _]}, _status, _action),
    do: description

  defp task(_activity, :iterating, _action), do: "Running tools"
  defp task(_activity, :working, _action), do: "Thinking"
  defp task(_activity, _status, _action), do: "Agent activity"

  @spec context_status(WorkspaceStatus.t()) :: AgentContext.status()
  defp context_status(status) when status in [:approval_waiting, :needs_you, :needs_review],
    do: :needs_you

  defp context_status(:thinking), do: :working
  defp context_status(:tool_executing), do: :iterating
  defp context_status(:error), do: :errored
  defp context_status(:done), do: :done
  defp context_status(status) when status in [:idle, :plan, :stopped, nil], do: :idle

  @spec active_action(Activity.t(), MingaAgent.ToolApproval.Public.t() | nil) :: String.t() | nil
  defp active_action(_activity, %MingaAgent.ToolApproval.Public{name: name}),
    do: "Awaiting approval for #{name}"

  defp active_action(%Activity{active_action: action}, nil), do: action

  @spec progress(Activity.t(), String.t() | nil) :: Progress.t()
  defp progress(%Activity{} = activity, action) do
    %Progress{
      active_action: action,
      tool_count: activity.tool_count,
      file_count: Activity.file_count(activity),
      review_hint: ""
    }
  end

  @spec todos(Activity.t()) :: [Todo.t()]
  defp todos(%Activity{todos: todos}) do
    Enum.map(todos, fn todo ->
      %Todo{description: todo.description, status: todo.status}
    end)
  end
end
