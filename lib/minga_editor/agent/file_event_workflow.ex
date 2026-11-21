defmodule MingaEditor.Agent.FileEventWorkflow do
  @moduledoc """
  Applies agent-authored file change events to buffers, review state, and tabs.

  Buffer and session actions run during the owner transition. Rendering is scheduled after all state transitions, then deferred remote reload notices are logged in their established order.

  Writes record every edit without selecting a preview or moving input focus.
  Dirty remote buffers keep human edits; their agent post-images remain in the timeline for explicit review, and an explicit save still checks conflicts.
  """

  alias Minga.Buffer
  alias Minga.Log
  alias Minga.Distribution.ConnectionManager
  alias Minga.Project.FileRef
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.EditPublication
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.FileChange
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.Shell.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Remote
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.File
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaAgent.Session

  @typep reload_notice ::
           {:info, String.t()} | {:warning, String.t()} | {:error, String.t()}

  @doc "Applies a file change and composes buffer reload, UI, render, and logging actions."
  @spec changed(EditorState.t(), FileChange.t()) :: EditorState.t()
  def changed(%EditorState{} = state, %FileChange{path: path} = change) do
    {state, notices} = reload_remote_buffer_if_open(state, change)

    state
    |> record_file_activity(path)
    |> record_edit(change)
    |> track_active_shell_agent_file(path)
    |> associate_file_with_agent_workspace(path)
    |> EditPublication.record_edit(Runtime.active_session(state.shell_runtime), path)
    |> add_file_changed_message(change)
    |> refresh_selected_preview(path)
    |> MingaEditor.schedule_render(16)
    |> log_reload_notices(notices)
  end

  @spec record_edit(EditorState.t(), FileChange.t()) :: EditorState.t()
  defp record_edit(state, change) do
    ui = state.workspace.agent_ui
    timeline = EditTimeline.record_edit(ui.view.edit_timeline, change)
    TraditionalWorkflow.install_agent_ui(state, UIState.replace_edit_timeline(ui, timeline))
  end

  @spec refresh_selected_preview(EditorState.t(), String.t()) :: EditorState.t()
  defp refresh_selected_preview(state, path) do
    ui = state.workspace.agent_ui
    preview = Preview.refresh_after_write(ui.view.preview, path)
    TraditionalWorkflow.install_agent_ui(state, UIState.replace_preview(ui, preview))
  end

  @spec reload_remote_buffer_if_open(EditorState.t(), FileChange.t()) ::
          {EditorState.t(), [reload_notice()]}
  defp reload_remote_buffer_if_open(state, %FileChange{after_content: :absent}), do: {state, []}

  defp reload_remote_buffer_if_open(state, %FileChange{path: path, after_content: after_content}) do
    case current_remote_target(state) do
      {:ok, server_name, remote_node} ->
        reload_remote_buffer(
          state,
          server_name,
          normalize_remote_path(remote_node, path),
          after_content
        )

      :error ->
        reload_tracked_remote_buffers(state, path, after_content)
    end
  end

  @spec current_remote_target(EditorState.t()) :: {:ok, String.t(), node()} | :error
  defp current_remote_target(state) do
    case Runtime.active_session(state.shell_runtime) do
      pid when is_pid(pid) and node(pid) != node() -> remote_target(node(pid))
      _session -> :error
    end
  end

  @spec remote_target(node()) :: {:ok, String.t(), node()} | :error
  defp remote_target(remote_node) do
    case ConnectionManager.server_name_for_node(remote_node) do
      {:ok, server_name} -> {:ok, server_name, remote_node}
      {:error, :not_found} -> :error
    end
  end

  @spec normalize_remote_path(node(), String.t()) :: String.t()
  defp normalize_remote_path(remote_node, path) do
    :erpc.call(remote_node, Path, :expand, [path], 5_000)
  catch
    :exit, _reason -> path
    :error, {:erpc, _reason} -> path
  end

  @spec reload_tracked_remote_buffers(EditorState.t(), String.t(), String.t()) ::
          {EditorState.t(), [reload_notice()]}
  defp reload_tracked_remote_buffers(state, path, after_content) do
    state.remote
    |> matching_remote_buffers(path)
    |> Enum.reduce({state, []}, fn {_server_name, remote_path, pid}, {current_state, notices} ->
      {current_state, new_notices} =
        reload_remote_buffer_content(current_state, pid, remote_path, after_content)

      {current_state, new_notices ++ notices}
    end)
  end

  @spec matching_remote_buffers(Remote.t(), String.t()) :: [{String.t(), String.t(), pid()}]
  defp matching_remote_buffers(remote, path) do
    {direct_matches, fallback_candidates} =
      remote
      |> Remote.all_buffers()
      |> Enum.split_with(fn {_server_name, remote_path, _pid} -> remote_path == path end)

    fallback_matches =
      fallback_candidates
      |> Enum.group_by(fn {server_name, _remote_path, _pid} -> server_name end)
      |> Enum.flat_map(fn {server_name, buffers} ->
        normalized_path = normalize_remote_path_for_server(server_name, path, buffers)

        Enum.filter(buffers, fn {_server_name, remote_path, _pid} ->
          remote_path == normalized_path
        end)
      end)

    direct_matches ++ fallback_matches
  end

  @spec normalize_remote_path_for_server(String.t(), String.t(), [{String.t(), String.t(), pid()}]) ::
          String.t()
  defp normalize_remote_path_for_server(server_name, path, buffers) do
    case remote_node_for_server(server_name, buffers) do
      {:ok, remote_node} -> normalize_remote_path(remote_node, path)
      :error -> path
    end
  end

  @spec remote_node_for_server(String.t(), [{String.t(), String.t(), pid()}]) ::
          {:ok, node()} | :error
  defp remote_node_for_server(server_name, buffers) do
    case ConnectionManager.node_for_server(server_name) do
      {:ok, remote_node} -> {:ok, remote_node}
      {:error, _reason} -> remote_node_from_buffers(buffers)
    end
  catch
    :exit, _reason -> remote_node_from_buffers(buffers)
  end

  @spec remote_node_from_buffers([{String.t(), String.t(), pid()}]) :: {:ok, node()} | :error
  defp remote_node_from_buffers([{_server_name, _remote_path, pid} | _rest]) do
    case Buffer.storage(pid) do
      {:remote, remote_node, _base_path} -> {:ok, remote_node}
      _storage -> :error
    end
  catch
    :exit, _reason -> :error
  end

  defp remote_node_from_buffers([]), do: :error

  @spec reload_remote_buffer(EditorState.t(), String.t(), String.t(), String.t()) ::
          {EditorState.t(), [reload_notice()]}
  defp reload_remote_buffer(state, server_name, path, after_content) do
    case Remote.buffer(state.remote, server_name, path) do
      pid when is_pid(pid) -> reload_remote_buffer_content(state, pid, path, after_content)
      _missing -> {state, []}
    end
  end

  @spec reload_remote_buffer_content(EditorState.t(), pid(), String.t(), String.t()) ::
          {EditorState.t(), [reload_notice()]}
  defp reload_remote_buffer_content(state, pid, path, after_content) do
    reload_remote_buffer_content(Buffer.dirty?(pid), state, pid, path, after_content)
  catch
    :exit, reason ->
      {state, [{:error, "Failed to reload remote file #{path}: #{inspect(reason)}"}]}
  end

  @spec reload_remote_buffer_content(
          boolean(),
          EditorState.t(),
          pid(),
          String.t(),
          String.t()
        ) :: {EditorState.t(), [reload_notice()]}
  defp reload_remote_buffer_content(true, state, _pid, path, _after_content) do
    # Remote retains the buffer identity and the timeline records the post-image below.
    # Leave the dirty human buffer intact until an explicit review or save.
    state =
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
        state,
        "Agent modified this file. Review agent changes or keep editing. Save will check for conflicts."
      )

    {state, [{:warning, "Agent modified dirty remote file #{Path.basename(path)}"}]}
  end

  defp reload_remote_buffer_content(false, state, pid, path, after_content) do
    Buffer.accept_saved_content(pid, after_content)
    {state, [{:info, "Agent updated #{Path.basename(path)}"}]}
  end

  @spec log_reload_notices(EditorState.t(), [reload_notice()]) :: EditorState.t()
  defp log_reload_notices(state, notices) do
    Enum.each(notices, fn
      {:info, message} -> Log.info(:editor, message)
      {:warning, message} -> Log.warning(:editor, message)
      {:error, message} -> Log.error(:agent, message)
    end)

    state
  end

  @spec add_file_changed_message(EditorState.t(), FileChange.t()) :: EditorState.t()
  defp add_file_changed_message(state, %FileChange{path: path, tool_name: tool_name}) do
    case Runtime.active_session(state.shell_runtime) do
      pid when is_pid(pid) ->
        short_path = shorten_to_relative(state, path)
        Session.add_system_message(pid, "#{file_change_verb(tool_name)} #{short_path}")
        state

      _session ->
        state
    end
  catch
    :exit, _reason -> state
  end

  @spec file_change_verb(String.t()) :: String.t()
  defp file_change_verb("write"), do: "Wrote"
  defp file_change_verb("edit"), do: "Edited"
  defp file_change_verb(_tool_name), do: "Modified"

  @spec shorten_to_relative(EditorState.t(), String.t()) :: String.t()
  defp shorten_to_relative(state, path) do
    case project_root(state) do
      root when is_binary(root) -> Path.relative_to(path, root)
      _root -> Path.basename(path)
    end
  end

  @spec record_file_activity(EditorState.t(), String.t()) :: EditorState.t()
  defp record_file_activity(state, path) do
    ui = state.workspace.agent_ui
    activity = Activity.record_file(ui.view.activity, path)
    TraditionalWorkflow.install_agent_ui(state, UIState.replace_activity(ui, activity))
  end

  @spec track_active_shell_agent_file(EditorState.t(), String.t()) :: EditorState.t()
  defp track_active_shell_agent_file(state, path) do
    state = Workflow.ensure_available(state)
    session = Runtime.active_session(state.shell_runtime)
    track_shell_agent_file(state, session, path)
  end

  @spec track_shell_agent_file(EditorState.t(), pid() | nil, String.t()) :: EditorState.t()
  defp track_shell_agent_file(state, session, _path) when not is_pid(session), do: state

  defp track_shell_agent_file(state, session, path) do
    runtime =
      Runtime.track_agent_file(
        state.shell_runtime,
        Workflow.resolved_entries(),
        session,
        path
      )

    %{state | shell_runtime: runtime}
  end

  @spec associate_file_with_agent_workspace(EditorState.t(), String.t()) :: EditorState.t()
  defp associate_file_with_agent_workspace(state, path) do
    tab_bar = traditional_tab_bar(state)
    associate_file_with_agent_workspace(state, path, tab_bar)
  end

  @spec associate_file_with_agent_workspace(EditorState.t(), String.t(), TabBar.t() | nil) ::
          EditorState.t()
  defp associate_file_with_agent_workspace(state, _path, nil), do: state

  defp associate_file_with_agent_workspace(state, path, tab_bar) do
    session = Runtime.active_session(state.shell_runtime)

    with pid when is_pid(pid) <- session,
         {:ok, file_ref} <- file_ref_for_path(state, path),
         %Workspace{id: workspace_id} <- TabBar.find_workspace_by_session(tab_bar, pid),
         %Tab{id: tab_id} <-
           find_unassociated_file_tab(tab_bar, file_ref, workspace_id, state) do
      tab_bar =
        tab_bar
        |> TabBar.move_tab_to_workspace(tab_id, workspace_id)
        |> TabBar.retarget_workspace_file(workspace_id, nil, file_ref)

      install_tab_bar(state, tab_bar)
    else
      _unavailable -> state
    end
  end

  @spec traditional_tab_bar(EditorState.t()) :: TabBar.t() | nil
  defp traditional_tab_bar(state), do: Runtime.traditional_tab_bar(state.shell_runtime)

  @spec install_tab_bar(EditorState.t(), TabBar.t()) :: EditorState.t()
  defp install_tab_bar(%EditorState{} = state, %TabBar{} = tab_bar) do
    MingaEditor.WorkspaceWorkflow.install_tab_bar(state, tab_bar)
  end

  @spec file_ref_for_path(EditorState.t(), String.t()) :: {:ok, FileRef.t()} | {:error, term()}
  defp file_ref_for_path(state, path) do
    case project_root(state) do
      root when is_binary(root) -> FileRef.from_path(root, path)
      _root -> {:error, :missing_project_root}
    end
  end

  @spec project_root(EditorState.t()) :: String.t() | nil
  defp project_root(state), do: state.workspace.file_tree.project_root

  @spec find_unassociated_file_tab(TabBar.t(), FileRef.t(), non_neg_integer(), EditorState.t()) ::
          Tab.t() | nil
  defp find_unassociated_file_tab(tab_bar, %FileRef{} = file_ref, workspace_id, state) do
    Enum.find(tab_bar.tabs, fn tab ->
      tab.kind == :file and tab.group_id != workspace_id and
        FileRef.equal?(tab_file_ref(tab, state), file_ref)
    end)
  end

  @spec tab_file_ref(Tab.t(), EditorState.t()) :: FileRef.t() | nil
  defp tab_file_ref(%Tab{kind: :file, payload: %File{file_ref: %FileRef{} = file_ref}}, _state),
    do: file_ref

  defp tab_file_ref(%Tab{context: context}, state) do
    with %{buffers: %Buffers{active: buffer}} when is_pid(buffer) <-
           TabContext.to_workspace_map(context),
         path when is_binary(path) <- safe_buffer_path(buffer),
         root when is_binary(root) <- project_root(state),
         {:ok, file_ref} <- FileRef.from_path(root, path) do
      file_ref
    else
      _unavailable -> nil
    end
  end

  @spec safe_buffer_path(pid()) :: String.t() | nil
  defp safe_buffer_path(buffer) when is_pid(buffer) do
    Buffer.file_path(buffer)
  catch
    :exit, _reason -> nil
  end
end
