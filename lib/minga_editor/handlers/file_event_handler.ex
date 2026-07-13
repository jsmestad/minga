defmodule MingaEditor.Handlers.FileEventHandler do
  @moduledoc """
  Handler for file and git status events.

  File-tree events enter their workflow directly so timer and scheduler
  correlation stay in the Editor process. Unrelated generic editor effects are
  still returned for the existing universal dispatcher.
  """

  alias MingaEditor.FileTree.Freshness, as: FileTreeFreshness
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.State, as: EditorState

  @typedoc "Effects that the file event handler may return."
  @type file_effect ::
          :render
          | {:render, pos_integer()}
          | {:log_message, String.t()}
          | {:request_code_lens}
          | {:request_inlay_hints}
          | {:save_session_deferred}
          | {:handle_git_remote_result, reference(), term()}

  @doc """
  Dispatches a file/git event to the appropriate handler.

  Returns `{state, effects}` where effects encode all side-effectful
  operations.
  """
  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [file_effect()]}

  def handle(state, {:minga_event, :git_status_changed, event}) do
    handle_git_status_changed(state, event)
  end

  def handle(state, {:minga_event, :buffer_saved, %Minga.Events.BufferEvent{buffer: buf}}) do
    handle_buffer_saved(state, buf)
  end

  def handle(
        state,
        {:minga_event, :buffer_changed, %Minga.Events.BufferChangedEvent{buffer: buf}}
      ) do
    handle_buffer_changed(state, buf)
  end

  def handle(
        state,
        {:minga_event, :diagnostics_updated, %Minga.Events.DiagnosticsUpdatedEvent{uri: uri}}
      ) do
    handle_diagnostics_updated(state, uri)
  end

  def handle(state, {:minga_event, :file_written, %Minga.Events.FileWrittenEvent{path: path}}) do
    handle_file_changed(state, path)
  end

  def handle(
        state,
        {:minga_event, :project_rebuilt, %Minga.Events.ProjectRebuiltEvent{root: root}}
      ) do
    handle_project_rebuilt(state, root)
  end

  def handle(state, {:file_changed_on_disk, path}) when is_binary(path) do
    handle_file_changed(state, path)
  end

  def handle(state, {:file_tree_filter_walk, root, filter, entries})
      when is_binary(root) and is_binary(filter) and is_list(entries) do
    handle_filter_walk_result(state, root, filter, entries)
  end

  def handle(state, {:git_remote_result, ref, result}) when is_reference(ref) do
    {state, [{:handle_git_remote_result, ref, result}]}
  end

  def handle(state, _msg) do
    {state, []}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec handle_git_status_changed(EditorState.t(), Minga.Events.GitStatusEvent.t()) ::
          {EditorState.t(), [file_effect()]}
  defp handle_git_status_changed(
         state,
         %Minga.Events.GitStatusEvent{
           git_root: _git_root,
           entries: entries,
           branch: branch,
           ahead: ahead,
           behind: behind
         } = event
       ) do
    state = FileTreeFreshness.refresh_git_status(state, event)

    case EditorState.git_status_panel(state) do
      nil ->
        if FileTreeFreshness.open?(state), do: {state, [{:render, 16}]}, else: {state, []}

      _panel ->
        git_status_data = %{
          repo_state: :normal,
          branch: branch || "",
          ahead: ahead,
          behind: behind,
          entries: entries,
          entry_base_path: Minga.Project.resolve_root(),
          last_commit_message: event.last_commit_message,
          stash_count: event.stash_count
        }

        state =
          state
          |> EditorState.set_git_status_panel(GitStatusPanel.new(git_status_data))
          |> EditorState.ensure_shell_available()

        {shell_state, workspace} =
          EditorState.active_shell_module(state).handle_event(
            state.shell_state,
            state.workspace,
            {:git_status_changed, entries}
          )

        new_state = %{state | shell_state: shell_state, workspace: workspace}

        {new_state, [{:render, 16}]}
    end
  end

  @spec handle_buffer_saved(EditorState.t(), pid()) :: {EditorState.t(), [file_effect()]}
  defp handle_buffer_saved(state, saved_buf) do
    new_state =
      state
      |> FileTreeFreshness.refresh_git_status_from_cache()
      |> refresh_git_diff_views_for_buffer(saved_buf)
      |> EditorState.rebind_buffer_file_identity(saved_buf)

    effects = [
      {:request_code_lens},
      {:request_inlay_hints},
      {:render, 16}
    ]

    effects =
      if state.backend != :headless do
        Enum.concat(effects, [{:save_session_deferred}])
      else
        effects
      end

    {new_state, effects}
  end

  @spec refresh_git_diff_views_for_buffer(EditorState.t(), pid()) :: EditorState.t()
  defp refresh_git_diff_views_for_buffer(state, saved_buf) do
    module = :"Elixir.MingaGitPorcelain.Commands"

    if git_porcelain_running?() and Code.ensure_loaded?(module) and
         function_exported?(module, :refresh_diff_views_for_buffer, 2) do
      :erlang.apply(module, :refresh_diff_views_for_buffer, [state, saved_buf])
    else
      state
    end
  end

  @spec git_porcelain_running?() :: boolean()
  defp git_porcelain_running? do
    case Process.whereis(Minga.Extension.Registry) do
      nil -> false
      _pid -> git_porcelain_running_in_registry?()
    end
  catch
    :exit, _reason -> false
  end

  @spec git_porcelain_running_in_registry?() :: boolean()
  defp git_porcelain_running_in_registry? do
    case Minga.Extension.Registry.get(:minga_git_porcelain) do
      {:ok, %{status: :running}} -> true
      _ -> false
    end
  end

  @spec handle_buffer_changed(EditorState.t(), pid()) :: {EditorState.t(), [file_effect()]}
  defp handle_buffer_changed(state, buffer) do
    if FileTreeFreshness.buffer_under_tree?(state, buffer) do
      {state, [{:render, 16}]}
    else
      {state, []}
    end
  end

  @spec handle_diagnostics_updated(EditorState.t(), String.t()) ::
          {EditorState.t(), [file_effect()]}
  defp handle_diagnostics_updated(state, uri) do
    if FileTreeFreshness.diagnostic_uri_under_tree?(state, uri) do
      {state, [{:render, 16}]}
    else
      {state, []}
    end
  end

  @spec handle_file_changed(EditorState.t(), String.t()) :: {EditorState.t(), [file_effect()]}
  defp handle_file_changed(state, path) do
    if FileTreeFreshness.path_under_tree?(state, path) do
      {FileTreeFreshness.request_refresh(state, 50), []}
    else
      {state, []}
    end
  end

  @spec handle_project_rebuilt(EditorState.t(), String.t()) :: {EditorState.t(), [file_effect()]}
  defp handle_project_rebuilt(state, root) do
    state = FileTreeFreshness.update_project_root(state, root)
    {state, [{:render, 16}]}
  end

  @spec handle_filter_walk_result(EditorState.t(), String.t(), String.t(), [
          Minga.Project.FileTree.entry()
        ]) :: {EditorState.t(), [file_effect()]}
  defp handle_filter_walk_result(state, root, filter, entries) do
    file_tree =
      EditorState.file_tree_state(state)
      |> MingaEditor.State.FileTree.apply_filter_walk(root, filter, entries)

    {EditorState.set_file_tree(state, file_tree), [{:render, 16}]}
  end
end
