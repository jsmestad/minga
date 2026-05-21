defmodule MingaEditor.Commands.Workspace do
  @moduledoc """
  Workspace navigation and management commands.

  All navigation commands route through `EditorState.switch_tab/2` so
  the outgoing tab's context is snapshotted and the incoming tab's
  context is restored. Never mutate `tab_bar.active_id` directly.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Project.FileRef
  alias MingaAgent.ProjectView
  alias MingaAgent.Session
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.State.WorkspaceReview

  @type state :: EditorState.t()
  @type workspace_project_view_action :: :keep | :refresh | :clear

  @doc "Switch to the next workspace's first tab."
  @spec workspace_next(state()) :: state()
  def workspace_next(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    switch_via_workspace(state, TabBar.next_agent_workspace(tb))
  end

  @doc "Switch to the previous workspace's first tab."
  @spec workspace_prev(state()) :: state()
  def workspace_prev(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    switch_via_workspace(state, TabBar.prev_agent_workspace(tb))
  end

  @doc "Switch to the first manual workspace tab."
  @spec switch_to_manual_workspace(state()) :: state()
  def switch_to_manual_workspace(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    case TabBar.tabs_in_workspace(tb, 0) do
      [first | _] -> EditorState.switch_tab(state, first.id)
      [] -> state
    end
  end

  @doc "Toggle between manual workspace tabs and the last agent workspace."
  @spec workspace_toggle(state()) :: state()
  def workspace_toggle(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    current_ws = TabBar.active_workspace_id(tb)
    target_workspace_id = if current_ws == 0, do: last_agent_id(tb), else: 0
    target_tb = TabBar.switch_to_workspace(tb, target_workspace_id)
    switch_via_workspace(state, target_tb)
  end

  @doc """
  Close the active workspace and migrate its tabs to the manual workspace.

  The manual workspace (id 0) cannot be closed.
  """
  @spec workspace_close(state()) :: state()
  def workspace_close(%{shell_state: %{tab_bar: %TabBar{}}} = state) do
    state = sync_active_workspace_review(state)
    workspace = active_workspace(state)

    if workspace_closure_requires_review?(workspace) do
      EditorState.set_status(state, workspace_close_confirmation_copy(workspace))
    else
      close_active_workspace(state)
    end
  end

  @doc "Keeps the active workspace open after a draft close prompt."
  @spec workspace_close_keep(state()) :: state()
  def workspace_close_keep(state) do
    EditorState.set_status(state, "Keeping workspace open")
  end

  @doc "Shows the active workspace draft summary."
  @spec workspace_review_drafts(state()) :: state()
  def workspace_review_drafts(%{shell_state: %{tab_bar: %TabBar{}}} = state) do
    state = update_active_workspace_review(state, &review_drafts_workspace/1)
    EditorState.set_status(state, review_status_copy(active_workspace(state)))
  end

  @doc "Promotes reviewed workspace drafts into the project root."
  @spec workspace_promote(state()) :: state()
  def workspace_promote(state) do
    update_active_workspace_review(state, &promote_workspace/1)
  end

  @doc "Discards workspace drafts and conflicts."
  @spec workspace_discard(state()) :: state()
  def workspace_discard(state) do
    update_active_workspace_review(state, &discard_workspace/1)
  end

  @doc "Attempts to resolve conflicts after the user has chosen final content."
  @spec workspace_resolve_conflicts(state()) :: state()
  def workspace_resolve_conflicts(state) do
    update_active_workspace_review(state, &promote_workspace/1)
  end

  @doc "Discards drafts and then closes the active workspace."
  @spec workspace_discard_and_close(state()) :: state()
  def workspace_discard_and_close(state) do
    workspace_id = TabBar.active_workspace_id(state.shell_state.tab_bar)

    dead_project_view? =
      workspace_dead_project_view?(TabBar.get_workspace(state.shell_state.tab_bar, workspace_id))

    state
    |> sync_active_workspace_review()
    |> discard_and_close_workspace(workspace_id, dead_project_view?)
  end

  @spec discard_and_close_workspace(state(), non_neg_integer(), boolean()) :: state()
  defp discard_and_close_workspace(state, workspace_id, true) do
    keep_workspace_after_dead_project_view(state, workspace_id)
  end

  defp discard_and_close_workspace(state, workspace_id, false) do
    workspace = TabBar.get_workspace(state.shell_state.tab_bar, workspace_id)
    discard_and_close_workspace(state, workspace_id, workspace)
  end

  @spec discard_and_close_workspace(state(), non_neg_integer(), WorkspaceModel.t() | nil) ::
          state()
  defp discard_and_close_workspace(state, workspace_id, %WorkspaceModel{} = workspace) do
    workspace
    |> discard_workspace_and_close()
    |> handle_discard_and_close_result(state, workspace_id)
  end

  defp discard_and_close_workspace(state, _workspace_id, nil),
    do: EditorState.set_status(state, "No active workspace")

  @spec workspace_dead_project_view?(WorkspaceModel.t() | nil) :: boolean()
  defp workspace_dead_project_view?(%WorkspaceModel{project_view: %ProjectView{}} = workspace) do
    not WorkspaceModel.project_view_active?(workspace)
  end

  defp workspace_dead_project_view?(%WorkspaceModel{}), do: false
  defp workspace_dead_project_view?(nil), do: false

  @spec handle_discard_and_close_result(
          {:ok, WorkspaceModel.t(), workspace_project_view_action()} | {:error, term()},
          state(),
          non_neg_integer()
        ) :: state()
  defp handle_discard_and_close_result({:ok, updated, action}, state, workspace_id) do
    {state.shell_state.tab_bar, workspace_id}
    |> then(fn {tb, id} -> put_workspace_review_result({:ok, updated, action}, state, tb, id) end)
    |> close_active_workspace()
  end

  defp handle_discard_and_close_result({:error, :dead_project_view}, state, workspace_id) do
    keep_workspace_after_dead_project_view(state, workspace_id)
  end

  defp handle_discard_and_close_result({:error, reason}, state, _workspace_id) do
    EditorState.set_status(state, "Workspace discard and close failed: #{inspect(reason)}")
  end

  @spec keep_workspace_after_dead_project_view(state(), non_neg_integer()) :: state()
  defp keep_workspace_after_dead_project_view(state, workspace_id) do
    state
    |> clear_dead_workspace_project_view(workspace_id)
    |> EditorState.set_status("Workspace ProjectView became unavailable; workspace kept open")
  end

  @doc "Open the workspace picker."
  @spec workspace_list(state()) :: state()
  def workspace_list(state) do
    MingaEditor.PickerUI.open(state, MingaEditor.UI.Picker.WorkspaceSource)
  end

  @doc "Open the pending workspace reviews picker."
  @spec workspace_pending_reviews(state()) :: state()
  def workspace_pending_reviews(state) do
    MingaEditor.PickerUI.open(state, MingaEditor.UI.Picker.PendingReviewsSource)
  end

  @doc "Open the icon picker for the active workspace."
  @spec workspace_set_icon(state()) :: state()
  def workspace_set_icon(state) do
    MingaEditor.PickerUI.open(state, MingaEditor.UI.Picker.WorkspaceIconSource)
  end

  @doc """
  Rename the active workspace.

  GUI: the inline TextField in the group indicator handles rename
  natively (double-click or context menu). This keyboard path opens the
  prompt UI with the current name prefilled, which works in both TUI
  (minibuffer) and GUI (native prompt rendering).
  """
  @spec workspace_rename(state()) :: state()
  def workspace_rename(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    ws = TabBar.active_workspace(tb)
    current_name = if ws, do: ws.label, else: ""

    MingaEditor.PromptUI.open(state, MingaEditor.UI.Prompt.WorkspaceRename, default: current_name)
  end

  @doc "Jump to workspace by number (1-based, 0 = manual workspace)."
  @spec workspace_goto(state(), non_neg_integer()) :: state()
  def workspace_goto(%{shell_state: %{tab_bar: %TabBar{}}} = state, 0) do
    switch_to_manual_workspace(state)
  end

  def workspace_goto(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, number) do
    case Enum.at(agent_workspaces(tb), number - 1) do
      nil -> state
      %{id: id} -> switch_via_workspace(state, TabBar.switch_to_workspace(tb, id))
    end
  end

  @doc "Jump directly to a workspace by id."
  @spec workspace_goto_by_id(state(), non_neg_integer()) :: state()
  def workspace_goto_by_id(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, workspace_id) do
    switch_via_workspace(state, TabBar.switch_to_workspace(tb, workspace_id))
  end

  @spec active_workspace(state()) :: WorkspaceModel.t() | nil
  defp active_workspace(%{shell_state: %{tab_bar: %TabBar{} = tb}}),
    do: TabBar.active_workspace(tb)

  @spec close_active_workspace(state()) :: state()
  defp close_active_workspace(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    workspace_id = TabBar.active_workspace_id(tb)

    case TabBar.get_workspace(tb, workspace_id) do
      %WorkspaceModel{} = workspace ->
        case discard_workspace_project_view(workspace) do
          :ok ->
            stop_workspace_session(workspace)

            state
            |> update_workspace_project_view(workspace_id, nil)
            |> maybe_refresh_workspace_provider_project_view(workspace, nil)
            |> EditorState.set_tab_bar(TabBar.remove_workspace(tb, workspace_id))
            |> EditorState.sync_agent_ui_from_active_workspace()

          {:error, reason} ->
            EditorState.set_status(
              state,
              "Failed to discard workspace ProjectView: #{inspect(reason)}"
            )
        end

      nil ->
        state
    end
  end

  @spec workspace_closure_requires_review?(WorkspaceModel.t() | nil) :: boolean()
  defp workspace_closure_requires_review?(%WorkspaceModel{} = workspace),
    do: WorkspaceModel.review_pending?(workspace)

  defp workspace_closure_requires_review?(nil), do: false

  @spec workspace_close_confirmation_copy(WorkspaceModel.t() | nil) :: String.t()
  defp workspace_close_confirmation_copy(%WorkspaceModel{review: review}) do
    "Workspace has #{WorkspaceReview.draft_count(review)} draft file(s) and #{WorkspaceReview.conflict_count(review)} conflict file(s). Actions: Keep workspace, Review drafts, Discard drafts and close. Dirty buffers are separate and are not discarded here."
  end

  defp workspace_close_confirmation_copy(nil), do: "Workspace has drafts."

  @spec update_active_workspace_review(
          state(),
          (WorkspaceModel.t() ->
             {:ok, WorkspaceModel.t(), workspace_project_view_action()} | {:error, term()})
        ) :: state()
  defp update_active_workspace_review(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, fun)
       when is_function(fun, 1) do
    state = sync_active_workspace_review(state)
    workspace_id = TabBar.active_workspace_id(tb)
    workspace = TabBar.get_workspace(state.shell_state.tab_bar, workspace_id)
    apply_workspace_review_update(state, state.shell_state.tab_bar, workspace_id, workspace, fun)
  end

  @spec sync_active_workspace_review(state()) :: state()
  defp sync_active_workspace_review(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    workspace_id = TabBar.active_workspace_id(tb)
    workspace = TabBar.get_workspace(tb, workspace_id)
    sync_workspace_review_result(state, tb, workspace_id, workspace)
  end

  defp sync_active_workspace_review(state), do: state

  @spec sync_workspace_review_result(
          state(),
          TabBar.t(),
          non_neg_integer(),
          WorkspaceModel.t() | nil
        ) :: state()
  defp sync_workspace_review_result(state, tb, workspace_id, %WorkspaceModel{} = workspace) do
    workspace
    |> review_drafts_workspace()
    |> put_synced_workspace_review(state, tb, workspace_id)
  end

  defp sync_workspace_review_result(state, _tb, _workspace_id, nil), do: state

  @spec put_synced_workspace_review(
          {:ok, WorkspaceModel.t(), workspace_project_view_action()} | {:error, term()},
          state(),
          TabBar.t(),
          non_neg_integer()
        ) :: state()
  defp put_synced_workspace_review({:ok, updated, _action}, state, tb, workspace_id) do
    EditorState.set_tab_bar(state, TabBar.update_workspace(tb, workspace_id, fn _ -> updated end))
  end

  defp put_synced_workspace_review({:error, :dead_project_view}, state, _tb, workspace_id) do
    clear_dead_workspace_project_view(state, workspace_id)
  end

  defp put_synced_workspace_review({:error, _reason}, state, _tb, _workspace_id), do: state

  @spec apply_workspace_review_update(
          state(),
          TabBar.t(),
          non_neg_integer(),
          WorkspaceModel.t() | nil,
          (WorkspaceModel.t() ->
             {:ok, WorkspaceModel.t(), workspace_project_view_action()} | {:error, term()})
        ) :: state()
  defp apply_workspace_review_update(state, tb, workspace_id, %WorkspaceModel{} = workspace, fun) do
    workspace
    |> fun.()
    |> put_workspace_review_result(state, tb, workspace_id)
  end

  defp apply_workspace_review_update(state, _tb, _workspace_id, nil, _fun) do
    EditorState.set_status(state, "No active workspace")
  end

  @spec put_workspace_review_result(
          {:ok, WorkspaceModel.t(), workspace_project_view_action()} | {:error, term()},
          state(),
          TabBar.t(),
          non_neg_integer()
        ) :: state()
  defp put_workspace_review_result({:ok, updated, action}, state, tb, workspace_id) do
    state =
      EditorState.set_tab_bar(
        state,
        TabBar.update_workspace(tb, workspace_id, fn _ -> updated end)
      )

    apply_workspace_project_view_action(state, workspace_id, action)
  end

  defp put_workspace_review_result({:error, :dead_project_view}, state, _tb, workspace_id) do
    state
    |> clear_dead_workspace_project_view(workspace_id)
    |> EditorState.set_status(
      "Workspace ProjectView became unavailable; workspace review was cleared"
    )
  end

  defp put_workspace_review_result({:error, reason}, state, _tb, _workspace_id) do
    EditorState.set_status(state, "Workspace review transition failed: #{inspect(reason)}")
  end

  @spec review_drafts_workspace(WorkspaceModel.t()) ::
          {:ok, WorkspaceModel.t(), workspace_project_view_action()} | {:error, term()}
  defp review_drafts_workspace(%WorkspaceModel{} = workspace) do
    case project_view_changed_files(workspace) do
      :dead_project_view ->
        {:error, :dead_project_view}

      nil ->
        {:ok, workspace, :keep}

      {:ok, files} ->
        review_drafts_workspace(
          workspace,
          files,
          workspace.review.state
        )
    end
  end

  @spec review_drafts_workspace(WorkspaceModel.t(), [FileRef.t()], WorkspaceReview.state()) ::
          {:ok, WorkspaceModel.t(), workspace_project_view_action()} | {:error, term()}
  defp review_drafts_workspace(%WorkspaceModel{} = workspace, [], _state) do
    {:ok, WorkspaceModel.set_review(workspace, WorkspaceReview.clean(workspace.review)), :keep}
  end

  defp review_drafts_workspace(%WorkspaceModel{} = workspace, files, :clean) do
    with {:ok, workspace} <-
           WorkspaceModel.transition_review(workspace, :agent_started_editing, files),
         {:ok, workspace} <- WorkspaceModel.transition_review(workspace, :agent_completed, files) do
      {:ok, workspace, :keep}
    end
  end

  defp review_drafts_workspace(%WorkspaceModel{} = workspace, files, :draft) do
    with {:ok, workspace} <- WorkspaceModel.transition_review(workspace, :agent_completed, files) do
      {:ok, workspace, :keep}
    end
  end

  defp review_drafts_workspace(%WorkspaceModel{} = workspace, files, _state) do
    {:ok,
     WorkspaceModel.set_review(
       workspace,
       WorkspaceReview.set_changed_files(workspace.review, files)
     ), :keep}
  end

  @spec project_view_changed_files(WorkspaceModel.t()) ::
          {:ok, [FileRef.t()]} | nil | :dead_project_view
  defp project_view_changed_files(%WorkspaceModel{project_view: %ProjectView{} = view}) do
    case ProjectView.diff(view) do
      {:ok, entries} -> {:ok, diff_entries_to_file_refs(view.project_root, entries)}
      {:error, _reason} -> nil
    end
  catch
    :exit, _ -> :dead_project_view
  end

  defp project_view_changed_files(%WorkspaceModel{}), do: nil

  @spec diff_entries_to_file_refs(String.t(), [map()]) :: [FileRef.t()]
  defp diff_entries_to_file_refs(project_root, entries) do
    entries
    |> Enum.flat_map(fn entry -> file_ref_from_diff_entry(project_root, entry) end)
    |> Enum.uniq_by(&{&1.project_root, &1.relative_path})
  end

  @spec file_ref_from_diff_entry(String.t(), map()) :: [FileRef.t()]
  defp file_ref_from_diff_entry(project_root, %{path: path}) when is_binary(path) do
    case FileRef.from_path(project_root, path) do
      {:ok, file_ref} -> [file_ref]
      {:error, _reason} -> []
    end
  end

  defp file_ref_from_diff_entry(_project_root, _entry), do: []

  @spec promote_workspace(WorkspaceModel.t()) ::
          {:ok, WorkspaceModel.t(), workspace_project_view_action()} | {:error, term()}
  defp promote_workspace(
         %WorkspaceModel{project_view: %ProjectView{}, review: %WorkspaceReview{state: :clean}} =
           workspace
       ) do
    {:ok, workspace, :refresh}
  end

  defp promote_workspace(
         %WorkspaceModel{project_view: nil, review: %WorkspaceReview{state: :clean}} = workspace
       ) do
    {:ok, workspace, :keep}
  end

  defp promote_workspace(%WorkspaceModel{project_view: %ProjectView{} = view} = workspace) do
    case ProjectView.promote(view, :project_root) do
      :ok ->
        with {:ok, workspace} <- WorkspaceModel.transition_review(workspace, :promote_succeeded) do
          {:ok, workspace, :refresh}
        end

      {:conflict, details} ->
        with {:ok, workspace} <-
               WorkspaceModel.transition_review(
                 workspace,
                 :promote_found_overlaps,
                 {conflict_files(view.project_root, details), details}
               ) do
          {:ok, workspace, :keep}
        end

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, _ -> {:error, :dead_project_view}
  end

  defp promote_workspace(%WorkspaceModel{}), do: {:error, :missing_project_view}

  @spec conflict_files(String.t(), map()) :: [FileRef.t()]
  defp conflict_files(project_root, %{conflicts: conflicts}) when is_list(conflicts) do
    conflicts
    |> Enum.map(&conflict_path/1)
    |> Enum.flat_map(fn path -> file_ref_from_diff_entry(project_root, %{path: path}) end)
  end

  defp conflict_files(_project_root, _details), do: []

  @spec conflict_path(term()) :: String.t() | nil
  defp conflict_path({:conflict, path, _reason}) when is_binary(path), do: path
  defp conflict_path({path, {:conflict, _details}}) when is_binary(path), do: path
  defp conflict_path({path, {:error, _reason}}) when is_binary(path), do: path
  defp conflict_path(_conflict), do: nil

  @spec discard_workspace(WorkspaceModel.t()) ::
          {:ok, WorkspaceModel.t(), workspace_project_view_action()} | {:error, term()}
  defp discard_workspace(
         %WorkspaceModel{project_view: %ProjectView{}, review: %WorkspaceReview{state: :clean}} =
           workspace
       ) do
    {:ok, workspace, :refresh}
  end

  defp discard_workspace(
         %WorkspaceModel{project_view: nil, review: %WorkspaceReview{state: :clean}} = workspace
       ) do
    {:ok, workspace, :keep}
  end

  defp discard_workspace(%WorkspaceModel{project_view: %ProjectView{} = view} = workspace) do
    with :ok <- ProjectView.discard(view),
         {:ok, workspace} <- WorkspaceModel.transition_review(workspace, :discard) do
      {:ok, workspace, :refresh}
    end
  catch
    :exit, _ -> {:error, :dead_project_view}
  end

  defp discard_workspace(%WorkspaceModel{} = workspace) do
    if WorkspaceReview.pending?(workspace.review) do
      with {:ok, workspace} <- WorkspaceModel.transition_review(workspace, :discard) do
        {:ok, workspace, :keep}
      end
    else
      {:ok, workspace, :keep}
    end
  end

  @spec discard_workspace_and_close(WorkspaceModel.t()) ::
          {:ok, WorkspaceModel.t(), workspace_project_view_action()} | {:error, term()}
  defp discard_workspace_and_close(
         %WorkspaceModel{project_view: %ProjectView{} = view} = workspace
       ) do
    with :ok <- ProjectView.discard(view),
         {:ok, workspace} <- WorkspaceModel.transition_review(workspace, :discard) do
      {:ok, workspace, :clear}
    end
  catch
    :exit, _ -> {:error, :dead_project_view}
  end

  defp discard_workspace_and_close(%WorkspaceModel{} = workspace) do
    if WorkspaceReview.pending?(workspace.review) do
      with {:ok, workspace} <- WorkspaceModel.transition_review(workspace, :discard) do
        {:ok, workspace, :keep}
      end
    else
      {:ok, workspace, :keep}
    end
  end

  @spec apply_workspace_project_view_action(
          state(),
          non_neg_integer(),
          workspace_project_view_action()
        ) :: state()
  defp apply_workspace_project_view_action(state, _workspace_id, :keep), do: state

  defp apply_workspace_project_view_action(state, workspace_id, :refresh) do
    refresh_workspace_project_view(state, workspace_id)
  end

  defp apply_workspace_project_view_action(state, workspace_id, :clear) do
    case TabBar.get_workspace(state.shell_state.tab_bar, workspace_id) do
      %WorkspaceModel{} = workspace ->
        state
        |> update_workspace_project_view(workspace_id, nil)
        |> maybe_refresh_workspace_provider_project_view(workspace, nil)

      nil ->
        state
    end
  end

  @spec refresh_workspace_project_view(state(), non_neg_integer()) :: state()
  defp refresh_workspace_project_view(state, workspace_id) do
    workspace = TabBar.get_workspace(state.shell_state.tab_bar, workspace_id)
    refresh_workspace_project_view(state, workspace_id, workspace)
  end

  @spec refresh_workspace_project_view(state(), non_neg_integer(), WorkspaceModel.t() | nil) ::
          state()
  defp refresh_workspace_project_view(state, workspace_id, %WorkspaceModel{} = workspace) do
    case workspace_project_root(state, workspace) do
      nil -> state
      root -> refresh_workspace_project_view(state, workspace_id, workspace, root)
    end
  end

  defp refresh_workspace_project_view(state, _workspace_id, nil), do: state

  @spec refresh_workspace_project_view(state(), non_neg_integer(), WorkspaceModel.t(), String.t()) ::
          state()
  defp refresh_workspace_project_view(state, workspace_id, workspace, root) do
    case ProjectView.overlay(root) do
      {:ok, project_view} ->
        replace_workspace_project_view(state, workspace_id, workspace, project_view)

      {:error, _reason} ->
        keep_or_clear_failed_project_view_refresh(state, workspace_id, workspace)
    end
  end

  @spec replace_workspace_project_view(
          state(),
          non_neg_integer(),
          WorkspaceModel.t(),
          ProjectView.t()
        ) :: state()
  defp replace_workspace_project_view(state, workspace_id, workspace, project_view) do
    state =
      state
      |> update_workspace_project_view(workspace_id, project_view)
      |> maybe_refresh_workspace_provider_project_view(workspace, project_view)

    _ = discard_workspace_project_view(workspace)
    state
  end

  @spec keep_or_clear_failed_project_view_refresh(state(), non_neg_integer(), WorkspaceModel.t()) ::
          state()
  defp keep_or_clear_failed_project_view_refresh(state, workspace_id, workspace) do
    if WorkspaceModel.project_view_active?(workspace) do
      state
    else
      clear_dead_workspace_project_view(state, workspace_id)
    end
  end

  @spec workspace_project_root(state(), WorkspaceModel.t()) :: String.t() | nil
  defp workspace_project_root(%{workspace: %{file_tree: %{project_root: root}}}, _workspace)
       when is_binary(root), do: root

  defp workspace_project_root(_state, %WorkspaceModel{project_view: %ProjectView{} = view}),
    do: view.project_root

  defp workspace_project_root(_state, _workspace), do: nil

  @spec update_workspace_project_view(state(), non_neg_integer(), ProjectView.t() | nil) ::
          state()
  defp update_workspace_project_view(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         workspace_id,
         project_view
       ) do
    tb =
      TabBar.update_workspace(
        tb,
        workspace_id,
        &WorkspaceModel.set_project_view(&1, project_view)
      )

    EditorState.set_tab_bar(state, tb)
  end

  defp update_workspace_project_view(state, _workspace_id, _project_view), do: state

  @spec discard_workspace_project_view(ProjectView.t() | WorkspaceModel.t()) ::
          :ok | {:error, term()}
  defp discard_workspace_project_view(%ProjectView{} = view) do
    ProjectView.discard(view)
  catch
    :exit, _ -> {:error, :dead_project_view}
  end

  defp discard_workspace_project_view(%WorkspaceModel{project_view: %ProjectView{} = view}),
    do: discard_workspace_project_view(view)

  defp discard_workspace_project_view(%WorkspaceModel{}), do: :ok

  @spec clear_dead_workspace_project_view(state(), non_neg_integer()) :: state()
  defp clear_dead_workspace_project_view(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         workspace_id
       ) do
    case TabBar.get_workspace(tb, workspace_id) do
      %WorkspaceModel{} = workspace ->
        cleared_workspace =
          workspace
          |> WorkspaceModel.set_project_view(nil)
          |> WorkspaceModel.set_review(WorkspaceReview.clean(workspace.review))

        state
        |> EditorState.set_tab_bar(
          TabBar.update_workspace(tb, workspace_id, fn _ -> cleared_workspace end)
        )
        |> maybe_refresh_workspace_provider_project_view(workspace, nil)

      nil ->
        state
    end
  end

  defp clear_dead_workspace_project_view(state, _workspace_id), do: state

  @spec maybe_refresh_workspace_provider_project_view(
          state(),
          WorkspaceModel.t() | nil,
          ProjectView.t() | nil
        ) :: state()
  defp maybe_refresh_workspace_provider_project_view(
         state,
         %WorkspaceModel{session: session},
         project_view
       )
       when is_pid(session) do
    case Session.get_provider(session) do
      nil -> state
      provider -> refresh_workspace_provider_project_view(state, provider, project_view)
    end
  catch
    :exit, _ -> state
  end

  defp maybe_refresh_workspace_provider_project_view(state, _workspace, _project_view), do: state

  @spec refresh_workspace_provider_project_view(state(), pid(), ProjectView.t() | nil) :: state()
  defp refresh_workspace_provider_project_view(state, provider, project_view) do
    case MingaAgent.Providers.Native.refresh_project_view(provider, project_view) do
      :ok -> state
      {:error, _reason} -> state
    end
  catch
    :exit, _ -> state
  end

  @spec stop_workspace_session(WorkspaceModel.t() | nil) :: :ok
  defp stop_workspace_session(%WorkspaceModel{session: session}) when is_pid(session) do
    AgentSession.stop_session_pid(session)
    :ok
  end

  defp stop_workspace_session(_workspace), do: :ok

  @spec review_status_copy(WorkspaceModel.t() | nil) :: String.t()
  defp review_status_copy(%WorkspaceModel{review: %WorkspaceReview{} = review}) do
    "Workspace drafts: #{WorkspaceReview.draft_count(review)} draft file(s), #{WorkspaceReview.conflict_count(review)} conflict file(s). Dirty buffers are separate."
  end

  defp review_status_copy(nil), do: "No active workspace drafts"

  # Takes a TabBar with a potentially new active_id from a workspace switch.
  # Routes through EditorState.switch_tab so snapshots and restores happen properly.
  # No-op if the active tab didn't change.
  @spec switch_via_workspace(state(), TabBar.t()) :: state()
  defp switch_via_workspace(state, %TabBar{active_id: new_id}) do
    if new_id == state.shell_state.tab_bar.active_id do
      state
    else
      EditorState.switch_tab(state, new_id)
    end
  end

  # Find the last (most recently added) agent workspace id.
  @spec last_agent_id(TabBar.t()) :: non_neg_integer()
  defp last_agent_id(%TabBar{} = tb) do
    case List.last(agent_workspaces(tb)) do
      nil -> 0
      ws -> ws.id
    end
  end

  @spec agent_workspaces(TabBar.t()) :: [MingaEditor.State.Workspace.t()]
  defp agent_workspaces(%TabBar{workspaces: workspaces}) do
    Enum.filter(workspaces, &(&1.kind == :agent))
  end

  command(:workspace_next, "Next workspace", execute: &workspace_next/1)
  command(:workspace_prev, "Previous workspace", execute: &workspace_prev/1)

  command(:workspace_next_agent, "Next agent workspace", execute: &workspace_next/1)

  command(:manual_workspace, "Switch to manual workspace", execute: &switch_to_manual_workspace/1)
  command(:workspace_toggle, "Toggle last workspace", execute: &workspace_toggle/1)
  command(:workspace_close, "Close workspace", execute: &workspace_close/1)
  command(:workspace_close_keep, "Keep workspace", execute: &workspace_close_keep/1)

  command(:workspace_review_drafts, "Review workspace drafts",
    execute: &workspace_review_drafts/1
  )

  command(:workspace_promote, "Promote workspace drafts", execute: &workspace_promote/1)
  command(:workspace_discard, "Discard workspace drafts", execute: &workspace_discard/1)

  command(:workspace_resolve_conflicts, "Resolve workspace conflicts",
    execute: &workspace_resolve_conflicts/1
  )

  command(:workspace_discard_and_close, "Discard drafts and close workspace",
    execute: &workspace_discard_and_close/1
  )

  command(:workspace_list, "List workspaces", execute: &workspace_list/1)
  command(:workspace_pending_reviews, "Pending reviews", execute: &workspace_pending_reviews/1)
  command(:workspace_rename, "Rename workspace", execute: &workspace_rename/1)
  command(:workspace_set_icon, "Set workspace icon", execute: &workspace_set_icon/1)

  numbered_commands(:workspace_goto, 1..9, "Workspace",
    argument: :number,
    execute: &workspace_goto/2
  )
end
