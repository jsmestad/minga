defmodule MingaEditor.RenderModel.UI.AgentContextBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.AgentContext
  alias Minga.RenderModel.UI.AgentContext.Progress
  alias Minga.RenderModel.UI.AgentContext.Todo
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState

  @spec build(Context.t() | term()) :: AgentContext.t()
  def build(%Context{workspace: %{agent_ui: %{chat_lifecycle: :unavailable}}}), do: hidden()

  def build(%Context{} = ctx) do
    activity = get_activity(ctx)
    {status, action} = status_and_action(ctx, activity)

    if visible?(activity, status) do
      %AgentContext{
        visible: true,
        task: task(activity, status, action),
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

  def visible?(%Context{} = ctx) do
    activity = get_activity(ctx)
    {status, _action} = status_and_action(ctx, activity)
    visible?(activity, status)
  end

  def visible?(%{workspace: %{agent_ui: %{chat_lifecycle: {:failed, _failure}}}}), do: true

  def visible?(state) when is_map(state) do
    visible?(get_activity_from_state(state), context_status(agent_status_from_state(state)))
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

  @spec get_activity_from_state(map()) :: Activity.t()
  defp get_activity_from_state(state), do: state.workspace.agent_ui.view.activity

  @spec agent_status(Context.t()) :: atom()
  defp agent_status(%Context{
         intent: %{frame: %{shell_state: %TraditionalState{} = shell_state}}
       }),
       do: MingaEditor.State.Agent.display_status(TraditionalState.agent(shell_state))

  defp agent_status(%Context{}), do: :idle

  @spec agent_status_from_state(map()) :: atom()
  defp agent_status_from_state(state),
    do: MingaEditor.State.Agent.display_status(TraditionalState.agent(shell_state(state)))

  @spec shell_state(map()) :: TraditionalState.t()
  defp shell_state(%MingaEditor.RenderPipeline.Input{
         intent: %{frame: %{shell_state: %TraditionalState{} = shell_state}}
       }),
       do: shell_state

  defp shell_state(%{shell_runtime: %{state: %TraditionalState{} = shell_state}}), do: shell_state

  @spec status_and_action(Context.t(), Activity.t()) ::
          {AgentContext.status(), String.t() | nil}
  # A failed start needs the user, not an error badge, whatever the runtime last reported.
  defp status_and_action(
         %Context{workspace: %{agent_ui: %{chat_lifecycle: {:failed, failure}}}},
         _activity
       ),
       do: {:needs_you, start_failure_action(failure)}

  defp status_and_action(
         %Context{intent: %{frame: %{shell_state: %TraditionalState{} = shell_state}}} = ctx,
         activity
       ) do
    case TraditionalState.agent(shell_state).pending_question do
      %MingaEditor.Agent.PendingQuestion{} -> {:needs_you, "Waiting for your answer"}
      nil -> {context_status(agent_status(ctx)), active_action(activity, pending_approval(ctx))}
    end
  end

  defp status_and_action(%Context{}, activity),
    do: {:idle, active_action(activity, nil)}

  @spec start_failure_action(StartFailure.t()) :: String.t()
  defp start_failure_action(%StartFailure{remedy: :set_up_provider}), do: "Agent needs setup"
  defp start_failure_action(%StartFailure{}), do: "Agent could not start"

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

  @spec context_status(atom()) :: AgentContext.status()
  defp context_status(:approval_waiting), do: :needs_you
  defp context_status(:thinking), do: :working
  defp context_status(:tool_executing), do: :iterating
  defp context_status(:error), do: :errored
  defp context_status(:idle), do: :idle
  defp context_status(:plan), do: :idle
  defp context_status(nil), do: :idle

  @spec pending_approval(Context.t()) :: MingaAgent.ToolApproval.Public.t() | nil
  defp pending_approval(%Context{
         intent: %{frame: %{shell_state: %TraditionalState{} = shell_state}}
       }),
       do:
         MingaEditor.Agent.PendingApproval.public(
           TraditionalState.agent(shell_state).pending_approval
         )

  defp pending_approval(%Context{}), do: nil

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
