defmodule MingaEditor.RenderModel.UI.AgentContextBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.AgentContext
  alias Minga.RenderModel.UI.AgentContext.Progress
  alias Minga.RenderModel.UI.AgentContext.Todo
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Frontend.Emit.Context

  @spec build(Context.t() | term()) :: AgentContext.t()
  def build(%Context{} = ctx) do
    activity = get_activity(ctx)
    status = agent_status(ctx)

    if visible?(activity, status) do
      %AgentContext{
        visible: true,
        task: task(activity, status),
        dispatch_timestamp: activity.started_at || DateTime.utc_now(),
        status: context_status(status),
        can_approve: can_approve?(ctx),
        todos: todos(activity),
        progress: progress(activity)
      }
    else
      hidden()
    end
  end

  def build(_other), do: hidden()

  @spec hidden() :: AgentContext.t()
  defp hidden do
    %AgentContext{visible: false}
  end

  @spec get_activity(Context.t()) :: Activity.t()
  defp get_activity(%{agent_ui: %{view: %{activity: %Activity{} = activity}}}), do: activity
  defp get_activity(_ctx), do: Activity.new()

  @spec agent_status(Context.t()) :: atom()
  defp agent_status(%{shell_state: %{agent: %{runtime: %{status: status}}}}), do: status
  defp agent_status(_ctx), do: :idle

  @spec visible?(Activity.t(), atom()) :: boolean()
  defp visible?(%Activity{}, status) when status in [:thinking, :tool_executing], do: true

  defp visible?(%Activity{todos: todos} = activity, _status) do
    todos != [] or activity.tool_count > 0 or Activity.file_count(activity) > 0
  end

  @spec task(Activity.t(), atom()) :: String.t()
  defp task(%Activity{active_action: action}, _status) when action not in ["", nil], do: action
  defp task(%Activity{todos: [%{description: description} | _]}, _status), do: description
  defp task(_activity, :tool_executing), do: "Running tools"
  defp task(_activity, :thinking), do: "Thinking"
  defp task(_activity, _status), do: "Agent activity"

  @spec context_status(atom()) :: AgentContext.status()
  defp context_status(:thinking), do: :working
  defp context_status(:tool_executing), do: :iterating
  defp context_status(:error), do: :errored
  defp context_status(:idle), do: :done
  defp context_status(:plan), do: :idle
  defp context_status(_status), do: :idle

  @spec can_approve?(Context.t()) :: boolean()
  defp can_approve?(%{shell_state: %{agent: %{pending_approval: approval}}}), do: approval != nil
  defp can_approve?(_ctx), do: false

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
