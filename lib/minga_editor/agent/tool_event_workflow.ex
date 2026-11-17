defmodule MingaEditor.Agent.ToolEventWorkflow do
  @moduledoc """
  Applies tool-family agent events to the foreground agent surface.

  Session snapshots remain authoritative for the active tool name. Each live workflow applies owner transitions first, then schedules its render directly. Stream batches reuse the tool-update transition without producing another render request.
  """

  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.Session

  @typep tool_end :: MingaAgent.Event.ToolEnd.t()
  @typep tool_completion :: {EditorState.t(), pid() | nil, tool_end()}

  @doc "Applies a tool-start event and schedules the resulting preview render."
  @spec started(EditorState.t(), String.t(), String.t(), map()) :: EditorState.t()
  def started(%EditorState{} = state, _tool_call_id, name, args), do: started(state, name, args)

  @doc "Applies a tool-start event without a tool-call identity."
  @spec started(EditorState.t(), String.t(), map()) :: EditorState.t()
  def started(%EditorState{} = state, name, args) do
    state
    |> transition_started(name, args)
    |> MingaEditor.schedule_render(16)
  end

  @doc "Applies a tool progress event and schedules the preview render."
  @spec updated(EditorState.t(), String.t(), String.t(), String.t()) :: EditorState.t()
  def updated(%EditorState{} = state, _tool_call_id, name, partial) do
    state
    |> transition_updated(name, partial)
    |> MingaEditor.schedule_render(50)
  end

  @doc "Applies a committed tool outcome from its originating Session."
  @spec ended(EditorState.t(), pid() | nil, tool_end()) :: EditorState.t()
  def ended(%EditorState{} = state, session, %MingaAgent.Event.ToolEnd{} = event) do
    {state, session, event}
    |> finish_tool_activity()
    |> sync_completed_tool()
    |> finish_tool_preview()
    |> MingaEditor.schedule_render(16)
  end

  @doc "Clears interrupted tool activity and schedules the preview render."
  @spec interrupted(EditorState.t(), String.t()) :: EditorState.t()
  def interrupted(%EditorState{} = state, _tool_call_id) do
    state
    |> transition_interrupted()
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

  @spec transition_started(EditorState.t(), String.t(), map()) :: EditorState.t()
  defp transition_started(state, "shell", args) do
    command = Map.get(args, "command", "")

    state
    |> update_activity(&Activity.start_tool(&1, "shell"))
    |> sync_active_tool_name("shell")
    |> update_preview(&Preview.set_shell(&1, command))
  end

  defp transition_started(state, "read_file", args) do
    path = Map.get(args, "path", "")

    state
    |> update_activity(&Activity.start_tool(&1, "read_file"))
    |> sync_active_tool_name("read_file")
    |> update_preview(&Preview.set_file(&1, path, ""))
  end

  defp transition_started(state, "list_directory", args) do
    path = Map.get(args, "path", ".")

    state
    |> update_activity(&Activity.start_tool(&1, "list_directory"))
    |> sync_active_tool_name("list_directory")
    |> update_preview(&Preview.set_directory(&1, path, []))
  end

  defp transition_started(state, name, _args) do
    state
    |> update_activity(&Activity.start_tool(&1, name))
    |> sync_active_tool_name(name)
  end

  @spec transition_updated(EditorState.t(), String.t(), String.t()) :: EditorState.t()
  defp transition_updated(state, "shell", partial) do
    state
    |> update_preview(&Preview.update_shell_output(&1, partial))
  end

  defp transition_updated(state, _name, _partial), do: state

  @spec finish_tool_activity(tool_completion()) :: tool_completion()
  defp finish_tool_activity({state, session, event}) do
    {update_activity(state, &Activity.finish_tool/1), session, event}
  end

  @spec sync_completed_tool(tool_completion()) :: tool_completion()
  defp sync_completed_tool({state, session, event}) do
    {sync_tool_name(state, session, nil), session, event}
  end

  @spec finish_tool_preview(tool_completion()) :: EditorState.t()
  defp finish_tool_preview(
         {state, _session, %MingaAgent.Event.ToolEnd{name: "shell", result: result} = event}
       ) do
    update_preview(state, &Preview.finish_shell(&1, result, shell_status(event)))
  end

  defp finish_tool_preview(
         {state, _session,
          %MingaAgent.Event.ToolEnd{name: "read_file", outcome: :complete, result: result}}
       ) do
    case state.workspace.agent_ui.view.preview.content do
      {:file, path, _content} -> update_preview(state, &Preview.set_file(&1, path, result))
      _other -> state
    end
  end

  defp finish_tool_preview(
         {state, _session,
          %MingaAgent.Event.ToolEnd{name: "list_directory", outcome: :complete, result: result}}
       ) do
    case state.workspace.agent_ui.view.preview.content do
      {:directory, path, _entries} ->
        entries = result |> String.split("\n") |> Enum.reject(&(&1 == ""))
        update_preview(state, &Preview.set_directory(&1, path, entries))

      _other ->
        state
    end
  end

  defp finish_tool_preview({state, _session, %MingaAgent.Event.ToolEnd{}}), do: state

  @spec shell_status(tool_end()) :: Preview.shell_status()
  defp shell_status(%MingaAgent.Event.ToolEnd{outcome: :error, reason: :approval_timeout}),
    do: :approval_expired

  defp shell_status(%MingaAgent.Event.ToolEnd{outcome: :complete}), do: :done

  defp shell_status(%MingaAgent.Event.ToolEnd{outcome: outcome})
       when outcome in [:error, :denied, :cancelled],
       do: outcome

  @spec transition_interrupted(EditorState.t()) :: EditorState.t()
  defp transition_interrupted(state) do
    state
    |> update_activity(&Activity.finish_tool/1)
    |> sync_active_tool_name(nil)
    |> update_preview(&Preview.clear/1)
  end

  @spec sync_active_tool_name(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp sync_active_tool_name(state, fallback_name) do
    sync_tool_name(state, Runtime.active_session(state.shell_runtime), fallback_name)
  end

  @spec sync_tool_name(EditorState.t(), pid() | nil, String.t() | nil) :: EditorState.t()
  defp sync_tool_name(state, session, fallback_name) when is_pid(session) do
    install_active_tool_name(state, session_active_tool_name(session), fallback_name)
  end

  defp sync_tool_name(state, _session, fallback_name),
    do: apply_active_tool_name_fallback(state, fallback_name)

  @spec install_active_tool_name(
          EditorState.t(),
          {:ok, String.t() | nil} | :error,
          String.t() | nil
        ) :: EditorState.t()
  defp install_active_tool_name(state, {:ok, active_tool_name}, _fallback_name),
    do: TraditionalWorkflow.install_agent_tool(state, active_tool_name)

  defp install_active_tool_name(state, :error, fallback_name),
    do: apply_active_tool_name_fallback(state, fallback_name)

  @spec apply_active_tool_name_fallback(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp apply_active_tool_name_fallback(state, name) when is_binary(name),
    do: TraditionalWorkflow.install_agent_tool(state, name)

  defp apply_active_tool_name_fallback(state, _name),
    do: TraditionalWorkflow.install_agent_tool_clear(state)

  @spec session_active_tool_name(pid()) :: {:ok, String.t() | nil} | :error
  defp session_active_tool_name(pid) do
    {:ok, Session.editor_snapshot(pid).active_tool_name}
  catch
    :exit, _reason -> :error
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
