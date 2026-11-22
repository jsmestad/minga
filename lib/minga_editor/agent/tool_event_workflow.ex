defmodule MingaEditor.Agent.ToolEventWorkflow do
  @moduledoc """
  Applies tool-family agent events to the foreground agent surface.

  Updates the editor's running-tool projection from correlated Session events.
  """

  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState

  @typep tool_end :: MingaAgent.Event.ToolEnd.t()

  @doc "Applies a tool-start event and schedules the resulting preview render."
  @spec started(EditorState.t(), String.t(), String.t(), map()) :: EditorState.t()
  def started(%EditorState{} = state, tool_call_id, name, args) do
    state
    |> update_running_tools(&Activity.start_tool(&1, tool_call_id, name))
    |> start_tool_preview(name, args)
    |> MingaEditor.schedule_render(16)
  end

  @doc "Applies a tool progress event and schedules the preview render."
  @spec updated(EditorState.t(), String.t(), String.t(), String.t()) :: EditorState.t()
  def updated(%EditorState{} = state, _tool_call_id, name, partial) do
    state
    |> transition_updated(name, partial)
    |> MingaEditor.schedule_render(50)
  end

  @doc "Applies the completed tool's outcome and leaves other calls running."
  @spec ended(EditorState.t(), tool_end()) :: EditorState.t()
  def ended(%EditorState{} = state, %MingaAgent.Event.ToolEnd{} = event) do
    state
    |> update_running_tools(&Activity.finish_tool(&1, event.tool_call_id))
    |> finish_tool_preview(event)
    |> MingaEditor.schedule_render(16)
  end

  @doc "Clears interrupted tool activity and schedules the preview render."
  @spec interrupted(EditorState.t(), String.t()) :: EditorState.t()
  def interrupted(%EditorState{} = state, tool_call_id) do
    state
    |> update_running_tools(&Activity.finish_tool(&1, tool_call_id))
    |> update_preview(&Preview.clear/1)
    |> MingaEditor.schedule_render(16)
  end

  @doc "Installs the latest tool-authored todo plan and schedules a render."
  @spec todo_plan_updated(EditorState.t(), [MingaAgent.TodoItem.t()]) :: EditorState.t()
  def todo_plan_updated(%EditorState{} = state, todos) when is_list(todos) do
    state
    |> update_activity(&Activity.set_todos(&1, todos))
    |> MingaEditor.schedule_render(16)
  end

  @doc false
  @spec replay(EditorState.t(), term()) :: EditorState.t()
  def replay(%EditorState{} = state, {:tool_update, _tool_call_id, "shell", partial}),
    do: update_preview(state, &Preview.update_shell_output(&1, partial))

  def replay(%EditorState{} = state, {:tool_update, _tool_call_id, _name, _partial}), do: state

  @spec start_tool_preview(EditorState.t(), String.t(), map()) :: EditorState.t()
  defp start_tool_preview(state, "shell", args) do
    command = Map.get(args, "command", "")
    update_preview(state, &Preview.set_shell(&1, command))
  end

  defp start_tool_preview(state, "read_file", args) do
    path = Map.get(args, "path", "")
    update_preview(state, &Preview.set_file(&1, path, ""))
  end

  defp start_tool_preview(state, "list_directory", args) do
    path = Map.get(args, "path", ".")
    update_preview(state, &Preview.set_directory(&1, path, []))
  end

  defp start_tool_preview(state, _name, _args), do: state

  @spec transition_updated(EditorState.t(), String.t(), String.t()) :: EditorState.t()
  defp transition_updated(state, "shell", partial) do
    state
    |> update_preview(&Preview.update_shell_output(&1, partial))
  end

  defp transition_updated(state, _name, _partial), do: state

  @spec finish_tool_preview(EditorState.t(), tool_end()) :: EditorState.t()
  defp finish_tool_preview(
         state,
         %MingaAgent.Event.ToolEnd{name: "shell", result: result} = event
       ) do
    update_preview(state, &Preview.finish_shell(&1, result, shell_status(event)))
  end

  defp finish_tool_preview(
         state,
         %MingaAgent.Event.ToolEnd{name: "read_file", outcome: :complete, result: result}
       ) do
    case state.workspace.agent_ui.view.preview.content do
      {:file, path, _content} -> update_preview(state, &Preview.set_file(&1, path, result))
      _other -> state
    end
  end

  defp finish_tool_preview(
         state,
         %MingaAgent.Event.ToolEnd{name: "list_directory", outcome: :complete, result: result}
       ) do
    case state.workspace.agent_ui.view.preview.content do
      {:directory, path, _entries} ->
        entries = result |> String.split("\n") |> Enum.reject(&(&1 == ""))
        update_preview(state, &Preview.set_directory(&1, path, entries))

      _other ->
        state
    end
  end

  defp finish_tool_preview(state, %MingaAgent.Event.ToolEnd{}), do: state

  @spec shell_status(tool_end()) :: Preview.shell_status()
  defp shell_status(%MingaAgent.Event.ToolEnd{outcome: :error, reason: :approval_timeout}),
    do: :approval_expired

  defp shell_status(%MingaAgent.Event.ToolEnd{outcome: :complete}), do: :done

  defp shell_status(%MingaAgent.Event.ToolEnd{outcome: outcome})
       when outcome in [:error, :denied, :cancelled],
       do: outcome

  @spec update_running_tools(EditorState.t(), (Activity.t() -> Activity.t())) :: EditorState.t()
  defp update_running_tools(state, transition) do
    ui = state.workspace.agent_ui
    activity = transition.(ui.view.activity)

    state
    |> TraditionalWorkflow.install_agent_ui(UIState.replace_activity(ui, activity))
    |> TraditionalWorkflow.install_agent_tool(Activity.active_tool_name(activity))
  end

  @spec update_activity(EditorState.t(), (Activity.t() -> Activity.t())) :: EditorState.t()
  defp update_activity(state, fun) when is_function(fun, 1) do
    TraditionalWorkflow.install_agent_ui(
      state,
      (fn ui -> UIState.replace_activity(ui, fun.(ui.view.activity)) end).(
        state.workspace.agent_ui
      )
    )
  end

  @spec update_preview(EditorState.t(), (Preview.t() -> Preview.t())) :: EditorState.t()
  defp update_preview(state, fun) when is_function(fun, 1) do
    TraditionalWorkflow.install_agent_ui(
      state,
      (fn ui ->
         UIState.replace_preview(ui, Preview.follow_tool_activity(ui.view.preview, fun))
       end).(state.workspace.agent_ui)
    )
  end
end
