# credo:disable-for-this-file Credo.Check.Refactor.Nesting
# credo:disable-for-this-file Credo.Check.Readability.PreferImplicitTry

defmodule MingaEditor.Commands.Workspace do
  @moduledoc """
  Workspace navigation and management commands.

  All navigation commands route through `EditorState.switch_tab/2` so
  the outgoing tab's context is snapshotted and the incoming tab's
  context is restored. Never mutate `tab_bar.active_id` directly.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
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
  def workspace_review_drafts(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    workspace_id = TabBar.active_workspace_id(tb)

    case TabBar.get_workspace(tb, workspace_id) do
      %WorkspaceModel{} = workspace ->
        case review_drafts_workspace(workspace) do
          {:ok, updated} ->
            state =
              EditorState.set_tab_bar(
                state,
                TabBar.update_workspace(tb, workspace_id, fn _ -> updated end)
              )

            EditorState.set_status(state, review_status_copy(updated))

          {:error, reason} ->
            EditorState.set_status(
              state,
              "Workspace review transition failed: #{inspect(reason)}"
            )
        end

      nil ->
        EditorState.set_status(state, "No active workspace")
    end
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
  def workspace_discard_and_close(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    workspace_id = TabBar.active_workspace_id(tb)

    case TabBar.get_workspace(tb, workspace_id) do
      %WorkspaceModel{} = workspace ->
        if workspace_session_alive?(workspace) do
          EditorState.set_status(state, "Stop the agent session before closing this workspace")
        else
          case discard_workspace(workspace) do
            {:ok, updated} ->
              state =
                EditorState.set_tab_bar(
                  state,
                  TabBar.update_workspace(tb, workspace_id, fn _ -> updated end)
                )

              close_discarded_active_workspace(state)

            {:error, reason} ->
              EditorState.set_status(
                state,
                "Workspace review transition failed: #{inspect(reason)}"
              )
          end
        end

      nil ->
        EditorState.set_status(state, "No active workspace")
    end
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

  @doc "Open a workspace picker to move the active file membership."
  @spec workspace_move_file(state()) :: state()
  def workspace_move_file(state) do
    open_workspace_target_picker(state, :move)
  end

  @doc "Open a workspace picker to copy the active file membership."
  @spec workspace_copy_file(state()) :: state()
  def workspace_copy_file(state) do
    open_workspace_target_picker(state, :copy)
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

  @spec open_workspace_target_picker(state(), :move | :copy) :: state()
  defp open_workspace_target_picker(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, operation) do
    with {:ok, file_ref} <- active_file_ref(state, tb),
         :ok <- other_workspace_available?(tb) do
      MingaEditor.PickerUI.open(state, MingaEditor.UI.Picker.WorkspaceTargetSource, %{
        operation: operation,
        source_workspace_id: TabBar.active_workspace_id(tb),
        file_ref: file_ref
      })
    else
      {:error, message} when is_binary(message) -> EditorState.set_status(state, message)
    end
  end

  defp open_workspace_target_picker(state, _operation),
    do: EditorState.set_status(state, "No workspace tab bar")

  @spec active_file_ref(state(), TabBar.t()) :: {:ok, FileRef.t()} | {:error, String.t()}
  defp active_file_ref(
         %{workspace: %{buffers: %{active: active}, file_tree: file_tree}},
         %TabBar{} = tb
       ) do
    case TabBar.active(tb) do
      %{kind: :file, file_ref: %FileRef{} = file_ref} -> {:ok, file_ref}
      %{kind: :file} -> active_buffer_file_ref(active, file_tree.project_root)
      _tab -> {:error, "Move and copy file require a file tab"}
    end
  end

  @spec active_buffer_file_ref(pid() | nil, String.t() | nil) ::
          {:ok, FileRef.t()} | {:error, String.t()}
  defp active_buffer_file_ref(active, project_root) when is_pid(active) do
    case Buffer.file_path(active) do
      path when is_binary(path) -> {:ok, path_file_ref_or_buffer(project_root, path, active)}
      _path -> {:ok, FileRef.from_buffer(active)}
    end
  catch
    :exit, _ -> {:error, "No active file"}
  end

  defp active_buffer_file_ref(_active, _project_root), do: {:error, "No active file"}

  @spec path_file_ref_or_buffer(String.t() | nil, String.t(), pid()) :: FileRef.t()
  defp path_file_ref_or_buffer(project_root, path, active) when is_binary(project_root) do
    case FileRef.from_path(project_root, path) do
      {:ok, file_ref} -> file_ref
      {:error, :outside_project} -> FileRef.from_buffer(active)
    end
  end

  defp path_file_ref_or_buffer(_project_root, _path, active), do: FileRef.from_buffer(active)

  @spec other_workspace_available?(TabBar.t()) :: :ok | {:error, String.t()}
  defp other_workspace_available?(%TabBar{} = tb) do
    active_workspace_id = TabBar.active_workspace_id(tb)

    if Enum.any?(tb.workspaces, &(&1.id != active_workspace_id)) do
      :ok
    else
      {:error, "No other workspaces"}
    end
  end

  @spec close_active_workspace(state()) :: state()
  defp close_active_workspace(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    workspace_id = TabBar.active_workspace_id(tb)

    case TabBar.get_workspace(tb, workspace_id) do
      %WorkspaceModel{} = workspace ->
        case workspace_session_alive?(workspace) do
          true ->
            EditorState.set_status(state, "Stop the agent session before closing this workspace")

          false ->
            case project_view_changed_files(workspace) do
              {:ok, []} ->
                case WorkspaceModel.close_project_view(workspace) do
                  :ok ->
                    EditorState.set_tab_bar(state, TabBar.remove_workspace(tb, workspace_id))

                  {:error, reason} ->
                    keep_workspace_open_after_close_failure(
                      state,
                      tb,
                      workspace,
                      workspace.review.changed_files,
                      reason
                    )
                end

              {:ok, files} ->
                keep_workspace_open_after_close_failure(
                  state,
                  tb,
                  workspace,
                  files,
                  :project_view_dirty
                )

              {:error, reason} ->
                keep_workspace_open_after_close_failure(
                  state,
                  tb,
                  workspace,
                  workspace.review.changed_files,
                  reason
                )
            end
        end

      nil ->
        state
    end
  end

  @spec close_discarded_active_workspace(state()) :: state()
  defp close_discarded_active_workspace(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    workspace_id = TabBar.active_workspace_id(tb)

    case TabBar.get_workspace(tb, workspace_id) do
      %WorkspaceModel{} = workspace ->
        case workspace_session_alive?(workspace) do
          true ->
            EditorState.set_status(state, "Stop the agent session before closing this workspace")

          false ->
            case WorkspaceModel.close_project_view(workspace) do
              :ok ->
                EditorState.set_tab_bar(state, TabBar.remove_workspace(tb, workspace_id))

              {:error, reason} ->
                keep_workspace_open_after_close_failure(
                  state,
                  tb,
                  workspace,
                  workspace.review.changed_files,
                  reason
                )
            end
        end

      nil ->
        state
    end
  end

  @spec workspace_session_alive?(WorkspaceModel.t()) :: boolean()
  defp workspace_session_alive?(%WorkspaceModel{session: session}) when is_pid(session) do
    Process.alive?(session)
  end

  defp workspace_session_alive?(_workspace), do: false

  @spec keep_workspace_open_after_close_failure(
          state(),
          TabBar.t(),
          WorkspaceModel.t(),
          [FileRef.t()],
          term()
        ) :: state()
  defp keep_workspace_open_after_close_failure(state, tb, workspace, files, reason) do
    review = WorkspaceReview.mark_needs_review(workspace.review, files, reason)

    updated_workspace =
      workspace
      |> WorkspaceModel.set_agent_status(:error)
      |> WorkspaceModel.set_review(review)

    state
    |> EditorState.set_tab_bar(
      TabBar.update_workspace(tb, workspace.id, fn _ -> updated_workspace end)
    )
    |> EditorState.set_status("Workspace close failed: #{inspect(reason)}")
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
    with {:ok, files} <- project_view_changed_files(workspace) do
      review_drafts_workspace(workspace, files, workspace.review.state)
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
          {:ok, [FileRef.t()]} | {:error, term()}
  defp project_view_changed_files(%WorkspaceModel{project_view: %ProjectView{} = view}) do
    with {:ok, entries} <- safe_project_view_diff(view) do
      {:ok, diff_entries_to_file_refs(view.project_root, entries)}
    end
  catch
    :exit, _ -> :dead_project_view
  end

  defp project_view_changed_files(%WorkspaceModel{}), do: {:ok, []}

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

  @spec safe_project_view_discard(ProjectView.t()) :: :ok | {:error, term()}
  defp safe_project_view_discard(%ProjectView{} = view) do
    safe_project_view_call(fn -> ProjectView.discard(view) end)
  end

  @spec safe_project_view_promote(ProjectView.t()) :: :ok | {:conflict, map()} | {:error, term()}
  defp safe_project_view_promote(%ProjectView{} = view) do
    safe_project_view_call(fn -> ProjectView.promote(view, :project_root) end)
  end

  @spec safe_project_view_diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  defp safe_project_view_diff(%ProjectView{} = view) do
    safe_project_view_call(fn -> ProjectView.diff(view) end)
  end

  @spec safe_project_view_call((-> term())) :: term()
  # credo:disable-for-next-line Credo.Check.Readability.PreferImplicitTry
  defp safe_project_view_call(fun) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:project_view_unavailable, reason}}
    end
  end

  @spec promote_workspace(WorkspaceModel.t()) :: {:ok, WorkspaceModel.t()} | {:error, term()}
  defp promote_workspace(%WorkspaceModel{project_view: %ProjectView{} = view} = workspace) do
    case safe_project_view_promote(view) do
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
    with :ok <- safe_project_view_discard(view) do
      WorkspaceModel.transition_review(workspace, :discard)
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

  @spec review_status_copy(WorkspaceModel.t()) :: String.t()
  defp review_status_copy(%WorkspaceModel{review: %WorkspaceReview{} = review}) do
    base =
      "Workspace drafts: #{WorkspaceReview.draft_count(review)} draft file(s), #{WorkspaceReview.conflict_count(review)} conflict file(s). Dirty buffers are separate."

    case review.last_error do
      nil -> base
      error -> base <> " Last error: #{inspect(error)}"
    end
  end

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
  command(:workspace_move_file, "Move file to workspace…", execute: &workspace_move_file/1)
  command(:workspace_copy_file, "Copy file to workspace…", execute: &workspace_copy_file/1)
  command(:workspace_rename, "Rename workspace", execute: &workspace_rename/1)
  command(:workspace_set_icon, "Set workspace icon", execute: &workspace_set_icon/1)

  numbered_commands(:workspace_goto, 1..9, "Workspace",
    argument: :number,
    execute: &workspace_goto/2
  )
end
