defmodule MingaEditor.RenderModel.UI.AgentContextBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.AgentContext
  alias Minga.RenderModel.UI.AgentContext.Progress
  alias Minga.RenderModel.UI.AgentContext.Todo
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState

  @spec build(Context.t() | term()) :: AgentContext.t()
  def build(%Context{} = ctx) do
    activity = get_activity(ctx)
    can_approve = can_approve?(ctx)
    status = context_status(agent_status(ctx), can_approve)

    if visible?(activity, status, can_approve) do
      %AgentContext{
        visible: true,
        task: task(activity, status),
        dispatch_timestamp: activity.started_at || DateTime.utc_now(),
        status: status,
        can_approve: can_approve,
        todos: todos(activity),
        progress: progress(activity)
      }
    else
      hidden()
    end
  end

  def build(_other), do: hidden()

  @spec visible?(Context.t() | map()) :: boolean()
  def visible?(%Context{} = ctx) do
    visible?(
      get_activity(ctx),
      context_status(agent_status(ctx), can_approve?(ctx)),
      can_approve?(ctx)
    )
  end

  def visible?(state) when is_map(state) do
    can_approve = can_approve_from_state(state)

    visible?(
      get_activity_from_state(state),
      context_status(agent_status_from_state(state), can_approve),
      can_approve
    )
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
       do: TraditionalState.agent(shell_state).runtime.status

  defp agent_status(%Context{}), do: :idle

  @spec agent_status_from_state(map()) :: atom()
  defp agent_status_from_state(state),
    do: TraditionalState.agent(shell_state(state)).runtime.status

  @spec can_approve_from_state(map()) :: boolean()
  defp can_approve_from_state(state),
    do: TraditionalState.agent(shell_state(state)).pending_approval != nil

  @spec shell_state(map()) :: TraditionalState.t()
  defp shell_state(%MingaEditor.RenderPipeline.Input{
         intent: %{frame: %{shell_state: %TraditionalState{} = shell_state}}
       }),
       do: shell_state

  defp shell_state(%{shell_runtime: %{state: %TraditionalState{} = shell_state}}), do: shell_state

  @spec visible?(Activity.t(), atom(), boolean()) :: boolean()
  defp visible?(%Activity{}, _status, true), do: true
  defp visible?(%Activity{}, status, false) when status in [:working, :iterating], do: true

  defp visible?(%Activity{todos: todos} = activity, _status, _can_approve) do
    todos != [] or activity.tool_count > 0 or Activity.file_count(activity) > 0
  end

  @spec task(Activity.t(), atom()) :: String.t()
  defp task(%Activity{active_action: action}, _status) when action not in ["", nil], do: action
  defp task(%Activity{todos: [%{description: description} | _]}, _status), do: description
  defp task(_activity, :iterating), do: "Running tools"
  defp task(_activity, :working), do: "Thinking"
  defp task(_activity, _status), do: "Agent activity"

  @spec context_status(atom(), boolean()) :: AgentContext.status()
  defp context_status(_status, true), do: :needs_you
  defp context_status(:thinking, false), do: :working
  defp context_status(:tool_executing, false), do: :iterating
  defp context_status(:error, false), do: :errored
  defp context_status(:idle, false), do: :done
  defp context_status(:plan, false), do: :idle
  defp context_status(_status, false), do: :idle

  @spec can_approve?(Context.t()) :: boolean()
  defp can_approve?(%Context{
         intent: %{frame: %{shell_state: %TraditionalState{} = shell_state}}
       }),
       do: TraditionalState.agent(shell_state).pending_approval != nil

  defp can_approve?(%Context{}), do: false

  @spec progress(Activity.t()) :: Progress.t()
  defp progress(%Activity{} = activity) do
    %Progress{
      active_action: activity.active_action,
      tool_count: activity.tool_count,
      file_count: Activity.file_count(activity),
      review_hint: "Review: approve or reject changes"
    }
  end

  @spec todos(Activity.t()) :: [Todo.t()]
  defp todos(%Activity{todos: todos}) do
    Enum.map(todos, fn todo ->
      %Todo{description: todo.description, status: todo.status}
    end)
  end
end
