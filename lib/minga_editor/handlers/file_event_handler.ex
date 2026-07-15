defmodule MingaEditor.Handlers.FileEventHandler do
  @moduledoc """
  Owns file, file-tree, save follow-up, and Git boundary actions.

  `dispatch/2` performs state transitions first and interprets focused actions
  in list order. File-tree refresh keeps its typed `Effect.Request` scheduler
  contract, stable root identity, bounded coalescing, supervised workers, and
  terminal outcomes. Save follow-ups run in the Editor process: LSP requests
  are issued before deferred session persistence and rendering.

  Git remote replies stay behind the existing dynamic extension boundary and
  are correlated by task monitor reference before this workflow receives them.
  Stale extension results are ignored, missing/stopped extensions are no-ops,
  and file-tree or LSP failures retain their existing domain reporting policy.
  """

  alias MingaEditor.FileTree.Freshness, as: FileTreeFreshness
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.LspActions
  alias MingaEditor.PickerUI
  alias MingaEditor.Renderer
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Shell.Workflow
  alias MingaEditor.State, as: EditorState

  @typedoc "Effects that the file event handler may return."
  @type file_effect ::
          {:render, pos_integer()}
          | {:request_code_lens}
          | {:request_inlay_hints}
          | {:save_session_deferred}
          | {:handle_git_remote_result, reference(), term()}

  @doc "Applies one file/Git event and its focused actions."
  @spec dispatch(EditorState.t(), term()) :: EditorState.t()
  def dispatch(%EditorState{} = state, message) do
    {state, effects} = handle(state, message)
    apply_effects(state, effects)
  end

  @doc "Lets the active Git extension correlate a monitored remote task termination."
  @spec handle_remote_task_down(EditorState.t(), reference(), term()) ::
          :not_matched | EditorState.t()
  def handle_remote_task_down(state, ref, reason) do
    module = :"Elixir.MingaGitPorcelain.Commands"

    if git_porcelain_running?() and Code.ensure_loaded?(module) and
         function_exported?(module, :handle_remote_task_down, 3) do
      :erlang.apply(module, :handle_remote_task_down, [state, ref, reason])
    else
      :not_matched
    end
  end

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

  def handle(state, {:git_remote_result, ref, result}) when is_reference(ref) do
    {state, [{:handle_git_remote_result, ref, result}]}
  end

  def handle(state, _msg) do
    {state, []}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec apply_effects(EditorState.t(), [file_effect()]) :: EditorState.t()
  defp apply_effects(state, []), do: state

  defp apply_effects(state, [effect | rest]) do
    state = apply_effect(state, effect)
    apply_effects(state, rest)
  end

  @spec apply_effect(EditorState.t(), file_effect()) :: EditorState.t()
  defp apply_effect(state, {:render, delay_ms}),
    do: MingaEditor.schedule_render(state, delay_ms)

  defp apply_effect(state, {:request_code_lens}), do: LspActions.code_lens(state)
  defp apply_effect(state, {:request_inlay_hints}), do: LspActions.inlay_hints(state)

  defp apply_effect(state, {:save_session_deferred}) do
    if state.frontend.backend != :headless, do: send(self(), :save_session)
    state
  end

  defp apply_effect(state, {:handle_git_remote_result, ref, result}),
    do: state |> handle_git_remote_result(ref, result) |> Renderer.render_or_async()

  @spec handle_git_remote_result(EditorState.t(), reference(), term()) :: EditorState.t()
  defp handle_git_remote_result(state, ref, result) do
    module = :"Elixir.MingaGitPorcelain.Commands"

    if git_porcelain_running?() and Code.ensure_loaded?(module) and
         function_exported?(module, :handle_remote_result, 3) do
      :erlang.apply(module, :handle_remote_result, [state, ref, result])
    else
      state
    end
  end

  @spec handle_git_status_changed(EditorState.t(), Minga.Events.GitStatusEvent.t()) ::
          {EditorState.t(), [file_effect()]}
  defp handle_git_status_changed(
         state,
         %Minga.Events.GitStatusEvent{
           git_root: git_root,
           entries: entries,
           branch: branch,
           ahead: ahead,
           behind: behind
         } = event
       ) do
    state = FileTreeFreshness.refresh_git_status(state, event)

    case SidebarWorkflow.git_status_panel(state) do
      nil ->
        if FileTreeFreshness.open?(state), do: {state, [{:render, 16}]}, else: {state, []}

      _panel ->
        git_status_data = %{
          repo_state: :normal,
          branch: branch || "",
          ahead: ahead,
          behind: behind,
          entries: entries,
          entry_base_path: git_root,
          last_commit_message: event.last_commit_message,
          stash_count: event.stash_count
        }

        state =
          state
          |> SidebarWorkflow.replace_git_status(GitStatusPanel.new(git_status_data))
          |> Workflow.ensure_available()

        {runtime, workspace} =
          Runtime.route_event(
            state.shell_runtime,
            state.workspace,
            {:git_status_changed, entries}
          )

        new_state = %{state | shell_runtime: runtime, workspace: workspace}
        {new_state, [{:render, 16}]}
    end
  end

  @spec handle_buffer_saved(EditorState.t(), pid()) :: {EditorState.t(), [file_effect()]}
  defp handle_buffer_saved(state, saved_buf) do
    saved_path = Minga.Buffer.file_path(saved_buf)

    new_state =
      state
      |> FileTreeFreshness.refresh_git_status_from_cache()
      |> refresh_git_diff_views_for_buffer(saved_buf)
      |> MingaEditor.BufferFileIdentity.rebind(saved_buf, saved_path)

    effects = [
      {:request_code_lens},
      {:request_inlay_hints},
      {:render, 16}
    ]

    effects =
      if state.frontend.backend != :headless do
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
    state =
      state
      |> FileTreeFreshness.update_project_root(root)
      |> maybe_refresh_file_picker()

    {state, [{:render, 16}]}
  end

  @spec maybe_refresh_file_picker(EditorState.t()) :: EditorState.t()
  defp maybe_refresh_file_picker(
         %{
           shell_runtime: %{
             state: %{
               modal: {:picker, %{picker_ui: %{source: MingaEditor.UI.Picker.FileSource}}}
             }
           }
         } = state
       ) do
    PickerUI.refresh_items(state)
  end

  defp maybe_refresh_file_picker(state), do: state
end
