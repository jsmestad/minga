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

  @doc "Applies a tool-end event and schedules a render when its preview changed."
  @spec ended(EditorState.t(), String.t(), String.t(), String.t(), atom()) :: EditorState.t()
  def ended(%EditorState{} = state, _tool_call_id, name, result, status),
    do: ended(state, name, result, status)

  @doc "Applies a tool-end event without a tool-call identity."
  @spec ended(EditorState.t(), String.t(), String.t(), atom()) :: EditorState.t()
  def ended(%EditorState{} = state, name, result, status) do
    case transition_ended(state, name, result, status) do
      {:render, state} -> MingaEditor.schedule_render(state, 16)
      {:no_render, state} -> state
    end
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

  @spec transition_ended(EditorState.t(), String.t(), String.t(), atom()) ::
          {:render | :no_render, EditorState.t()}
  defp transition_ended(state, "shell", result, status) do
    state =
      state
      |> update_activity(&Activity.finish_tool/1)
      |> sync_active_tool_name(nil)
      |> update_preview(&Preview.finish_shell(&1, result, shell_status(status)))

    {:render, state}
  end

  defp transition_ended(state, "read_file", result, _status) do
    state =
      state
      |> update_activity(&Activity.finish_tool/1)
      |> sync_active_tool_name(nil)

    case state.workspace.agent_ui.view.preview.content do
      {:file, path, _content} ->
        {:render, update_preview(state, &Preview.set_file(&1, path, result))}

      _other ->
        {:no_render, state}
    end
  end

  defp transition_ended(state, "list_directory", result, _status) do
    entries = result |> String.split("\n") |> Enum.reject(&(&1 == ""))

    state =
      state
      |> update_activity(&Activity.finish_tool/1)
      |> sync_active_tool_name(nil)

    case state.workspace.agent_ui.view.preview.content do
      {:directory, path, _entries} ->
        {:render, update_preview(state, &Preview.set_directory(&1, path, entries))}

      _other ->
        {:no_render, state}
    end
  end

  defp transition_ended(state, _name, _result, _status) do
    state =
      state
      |> update_activity(&Activity.finish_tool/1)
      |> sync_active_tool_name(nil)

    {:render, state}
  end

  @spec shell_status(atom()) :: :done | :error
  defp shell_status(:error), do: :error
  defp shell_status(_status), do: :done

  @spec transition_interrupted(EditorState.t()) :: EditorState.t()
  defp transition_interrupted(state) do
    state
    |> update_activity(&Activity.finish_tool/1)
    |> sync_active_tool_name(nil)
    |> update_preview(&Preview.clear/1)
  end

  @spec sync_active_tool_name(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp sync_active_tool_name(state, fallback_name) do
    case Runtime.active_session(state.shell_runtime) do
      pid when is_pid(pid) ->
        install_active_tool_name(state, session_active_tool_name(pid), fallback_name)

      _session ->
        apply_active_tool_name_fallback(state, fallback_name)
    end
  end

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
      (fn ui -> UIState.replace_preview(ui, fun.(ui.view.preview)) end).(state.workspace.agent_ui)
    )
  end
end
