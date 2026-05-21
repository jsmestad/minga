# credo:disable-for-this-file Credo.Check.Readability.PreferImplicitTry

defmodule MingaEditor.UI.Picker.WorkspaceTargetSource do
  @moduledoc """
  Picker source for moving or copying the active file membership to another workspace.

  The target list is snapshotted when the picker opens. The current workspace is excluded from target candidates.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Project.FileRef
  alias MingaAgent.ProjectView
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @type operation :: :move | :copy
  @type target_context :: %{
          operation: operation(),
          source_workspace_id: non_neg_integer(),
          file_ref: FileRef.t()
        }

  @agent_move_block "Move between agent workspaces is not supported in this release. Promote or discard drafts in the source workspace first."

  @impl true
  @spec title() :: String.t()
  def title, do: "Select workspace"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{picker_ui: %{context: %{confirm?: true} = context}}) do
    [
      %Item{
        id: {:confirm, :continue, context},
        label: "Continue",
        description: "Discard drafts for this file and move it"
      },
      %Item{
        id: {:confirm, :promote_first, context},
        label: "Promote first",
        description: "Promote workspace drafts before moving"
      },
      %Item{
        id: {:confirm, :cancel, context},
        label: "Cancel",
        description: "Keep the file in the source workspace"
      }
    ]
  end

  def candidates(%Context{tab_bar: %TabBar{} = tab_bar, picker_ui: %{context: context}}) do
    operation = Map.fetch!(context, :operation)
    source_workspace_id = Map.fetch!(context, :source_workspace_id)
    file_ref = Map.fetch!(context, :file_ref)

    tab_bar.workspaces
    |> Enum.reject(&(&1.id == source_workspace_id))
    |> Enum.map(&target_item(&1, operation, source_workspace_id, file_ref))
  end

  def candidates(_context), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:target, context}}, state) do
    apply_transfer(context, state)
  end

  def on_select(%Item{id: {:confirm, :continue, context}}, state) do
    context
    |> Map.put(:discard_drafts?, true)
    |> do_move(state)
  end

  def on_select(%Item{id: {:confirm, :promote_first, context}}, state) do
    promote_then_move(context, state)
  end

  def on_select(%Item{id: {:confirm, :cancel, _context}}, state) do
    EditorState.set_status(state, "Cancelled")
  end

  def on_select(_item, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec target_item(Workspace.t(), operation(), non_neg_integer(), FileRef.t()) :: Item.t()
  defp target_item(
         %Workspace{} = workspace,
         operation,
         source_workspace_id,
         %FileRef{} = file_ref
       ) do
    %Item{
      id:
        {:target,
         %{
           operation: operation,
           source_workspace_id: source_workspace_id,
           destination_workspace_id: workspace.id,
           file_ref: file_ref
         }},
      label: workspace.label,
      description: target_description(workspace),
      annotation: target_annotation(workspace),
      icon_color: workspace.color,
      two_line: true
    }
  end

  @spec target_description(Workspace.t()) :: String.t()
  defp target_description(%Workspace{kind: :manual, files: files}),
    do: "Project workspace • #{length(files)} file(s)"

  defp target_description(%Workspace{kind: :agent, files: files}),
    do: "Agent workspace • #{length(files)} file(s)"

  @spec target_annotation(Workspace.t()) :: String.t()
  defp target_annotation(%Workspace{kind: :manual}), do: "project"
  defp target_annotation(%Workspace{kind: :agent}), do: "agent"

  @spec apply_transfer(map(), term()) :: term()
  defp apply_transfer(%{operation: :copy} = context, state), do: do_copy(context, state)

  defp apply_transfer(%{operation: :move} = context, state) do
    case fetch_transfer_workspaces(state, context) do
      {:ok, tab_bar, source, destination} ->
        move_or_confirm(context, state, tab_bar, source, destination)

      {:error, message} ->
        EditorState.set_status(state, message)
    end
  end

  @spec do_copy(map(), term()) :: term()
  defp do_copy(context, state) do
    case fetch_transfer_workspaces(state, context) do
      {:ok, tab_bar, _source, destination} ->
        copy_to_destination(context, state, tab_bar, destination)

      {:error, message} ->
        EditorState.set_status(state, message)
    end
  end

  @spec copy_to_destination(map(), term(), TabBar.t(), Workspace.t()) :: term()
  defp copy_to_destination(context, state, tab_bar, destination) do
    file_ref = Map.fetch!(context, :file_ref)

    if Workspace.has_file?(destination, file_ref) do
      EditorState.set_status(
        state,
        "`#{FileRef.display_label(file_ref)}` is already in `#{destination.label}`"
      )
    else
      tab_bar =
        TabBar.update_workspace(tab_bar, destination.id, &Workspace.add_file(&1, file_ref))

      state
      |> EditorState.set_tab_bar(tab_bar)
      |> EditorState.set_status(
        "Copied `#{FileRef.display_label(file_ref)}` to `#{destination.label}`"
      )
    end
  end

  @spec move_or_confirm(map(), term(), TabBar.t(), Workspace.t(), Workspace.t()) :: term()
  defp move_or_confirm(_context, state, _tab_bar, %Workspace{kind: :agent}, %Workspace{
         kind: :agent
       }) do
    EditorState.set_status(state, @agent_move_block)
  end

  defp move_or_confirm(context, state, tab_bar, %Workspace{kind: :agent} = source, _destination) do
    file_ref = Map.fetch!(context, :file_ref)

    case refresh_agent_source_review(tab_bar, source) do
      {:ok, refreshed_tab_bar, refreshed_source, _fresh_files} ->
        refreshed_state = EditorState.set_tab_bar(state, refreshed_tab_bar)

        if draft_for_file?(refreshed_source, file_ref) do
          PickerUI.open(refreshed_state, __MODULE__, Map.put(context, :confirm?, true))
          |> EditorState.set_status(
            "Drafts for #{FileRef.display_label(file_ref)} will be discarded. Continue / Promote first / Cancel."
          )
        else
          do_move(context, refreshed_state)
        end

      {:error, :missing_project_view} ->
        EditorState.set_status(state, "Workspace move failed: missing project view")

      {:error, reason} ->
        EditorState.set_status(state, "Workspace move failed: #{inspect(reason)}")
    end
  end

  defp move_or_confirm(context, state, _tab_bar, _source, _destination),
    do: do_move(context, state)

  @spec do_move(map(), term()) :: term()
  defp do_move(context, state) do
    with {:ok, tab_bar, source, destination} <- fetch_transfer_workspaces(state, context),
         :ok <-
           maybe_discard_file_drafts(
             source,
             Map.fetch!(context, :file_ref),
             Map.get(context, :discard_drafts?, false)
           ) do
      file_ref = Map.fetch!(context, :file_ref)

      tab_bar =
        tab_bar
        |> TabBar.update_workspace(
          source.id,
          &remove_source_file(&1, file_ref, Map.get(context, :discard_drafts?, false))
        )
        |> TabBar.update_workspace(destination.id, &Workspace.add_file(&1, file_ref))

      state
      |> EditorState.set_tab_bar(tab_bar)
      |> EditorState.set_status(
        "Moved `#{FileRef.display_label(file_ref)}` to `#{destination.label}`"
      )
    else
      {:error, message} when is_binary(message) ->
        EditorState.set_status(state, message)

      {:error, reason} ->
        EditorState.set_status(state, "Workspace move failed: #{inspect(reason)}")
    end
  end

  @spec promote_then_move(map(), term()) :: term()
  defp promote_then_move(context, state) do
    with {:ok, tab_bar, source, _destination} <- fetch_transfer_workspaces(state, context),
         %ProjectView{} = view <- source.project_view,
         :ok <- safe_project_view_promote(view) do
      tab_bar =
        TabBar.update_workspace(
          tab_bar,
          source.id,
          &Workspace.set_review(&1, WorkspaceReview.clean(&1.review))
        )

      context
      |> Map.delete(:confirm?)
      |> do_move(EditorState.set_tab_bar(state, tab_bar))
    else
      nil ->
        EditorState.set_status(state, "Workspace promote failed: missing project view")

      {:conflict, details} ->
        record_promote_conflict(state, context, details)

      {:error, reason} ->
        EditorState.set_status(state, "Workspace promote failed: #{inspect(reason)}")
    end
  end

  @spec record_promote_conflict(term(), map(), map()) :: term()
  defp record_promote_conflict(state, context, details) do
    with {:ok, tab_bar, %Workspace{} = source, _destination} <-
           fetch_transfer_workspaces(state, context),
         %ProjectView{} = view <- source.project_view,
         {:ok, review} <- promote_conflict_review(source, view, details) do
      tab_bar = TabBar.update_workspace(tab_bar, source.id, &Workspace.set_review(&1, review))

      state
      |> EditorState.set_tab_bar(tab_bar)
      |> EditorState.set_status("Workspace promote found conflicts: #{inspect(details)}")
    else
      {:error, reason} ->
        EditorState.set_status(state, "Workspace promote failed: #{inspect(reason)}")

      nil ->
        EditorState.set_status(state, "Workspace promote failed: missing project view")
    end
  end

  @spec promote_conflict_review(Workspace.t(), ProjectView.t(), map()) ::
          {:ok, WorkspaceReview.t()} | {:error, term()}
  defp promote_conflict_review(%Workspace{} = source, %ProjectView{} = view, details) do
    with {:ok, changed_files} <- project_view_changed_files(view) do
      source.review
      |> WorkspaceReview.set_changed_files(changed_files)
      |> WorkspaceReview.promote_found_overlaps(
        conflict_files(source.project_root, details),
        details
      )
    end
  end

  @spec refresh_agent_source_review(TabBar.t(), Workspace.t()) ::
          {:ok, TabBar.t(), Workspace.t(), [FileRef.t()]} | {:error, term()}
  defp refresh_agent_source_review(
         tab_bar,
         %Workspace{project_view: %ProjectView{} = view} = source
       ) do
    with {:ok, fresh_files} <- project_view_changed_files(view) do
      review = sync_review_from_diff(source.review, fresh_files)
      refreshed_source = Workspace.set_review(source, review)

      refreshed_tab_bar =
        TabBar.update_workspace(tab_bar, source.id, fn _ -> refreshed_source end)

      {:ok, refreshed_tab_bar, refreshed_source, fresh_files}
    end
  end

  defp refresh_agent_source_review(_tab_bar, %Workspace{kind: :agent}),
    do: {:error, :missing_project_view}

  @spec sync_review_from_diff(WorkspaceReview.t(), [FileRef.t()]) :: WorkspaceReview.t()
  defp sync_review_from_diff(review, []) do
    WorkspaceReview.clean(review)
  end

  defp sync_review_from_diff(review, fresh_files) when is_list(fresh_files) do
    review = WorkspaceReview.set_changed_files(review, fresh_files)

    if review.state == :clean do
      case WorkspaceReview.agent_started_editing(review, fresh_files) do
        {:ok, synced} -> synced
        {:error, _reason} -> review
      end
    else
      review
    end
  end

  @spec project_view_changed_files(ProjectView.t()) :: {:ok, [FileRef.t()]} | {:error, term()}
  defp project_view_changed_files(%ProjectView{} = view) do
    with {:ok, entries} <- safe_project_view_diff(view) do
      {:ok, diff_entries_to_file_refs(view.project_root, entries)}
    end
  end

  @spec diff_entries_to_file_refs(String.t(), [map()]) :: [FileRef.t()]
  defp diff_entries_to_file_refs(project_root, entries) do
    entries
    |> Enum.flat_map(fn entry -> file_ref_from_diff_entry(project_root, entry) end)
    |> Enum.uniq_by(&{&1.project_root, &1.relative_path})
  end

  @spec conflict_files(String.t() | nil, map()) :: [FileRef.t()]
  defp conflict_files(project_root, %{conflicts: conflicts})
       when is_binary(project_root) and is_list(conflicts) do
    conflicts
    |> Enum.map(&conflict_path/1)
    |> Enum.flat_map(fn path -> file_ref_from_diff_entry(project_root, %{path: path}) end)
  end

  defp conflict_files(_project_root, _details), do: []

  @spec file_ref_from_diff_entry(String.t(), map()) :: [FileRef.t()]
  defp file_ref_from_diff_entry(project_root, %{path: path}) when is_binary(path) do
    case FileRef.from_path(project_root, path) do
      {:ok, file_ref} -> [file_ref]
      {:error, _reason} -> []
    end
  end

  defp file_ref_from_diff_entry(_project_root, _entry), do: []

  @spec conflict_path(term()) :: String.t() | nil
  defp conflict_path({:conflict, path, _reason}) when is_binary(path), do: path
  defp conflict_path({path, {:conflict, _details}}) when is_binary(path), do: path
  defp conflict_path({path, {:error, _reason}}) when is_binary(path), do: path
  defp conflict_path(_conflict), do: nil

  @spec fetch_transfer_workspaces(term(), map()) ::
          {:ok, TabBar.t(), Workspace.t(), Workspace.t()} | {:error, String.t()}
  defp fetch_transfer_workspaces(%{shell_state: %{tab_bar: %TabBar{} = tab_bar}}, context) do
    source_id = Map.fetch!(context, :source_workspace_id)
    destination_id = Map.fetch!(context, :destination_workspace_id)

    case {TabBar.get_workspace(tab_bar, source_id), TabBar.get_workspace(tab_bar, destination_id)} do
      {%Workspace{} = source, %Workspace{} = destination} -> {:ok, tab_bar, source, destination}
      {nil, _destination} -> {:error, "Source workspace no longer exists"}
      {_source, nil} -> {:error, "Destination workspace no longer exists"}
    end
  end

  defp fetch_transfer_workspaces(_state, _context), do: {:error, "No workspace tab bar"}

  @spec draft_for_file?(Workspace.t(), FileRef.t()) :: boolean()
  defp draft_for_file?(%Workspace{review: %WorkspaceReview{} = review}, %FileRef{} = file_ref) do
    Enum.any?(review.changed_files ++ review.conflict_files, &FileRef.equal?(&1, file_ref))
  end

  @spec maybe_discard_file_drafts(Workspace.t(), FileRef.t(), boolean()) :: :ok | {:error, term()}
  defp maybe_discard_file_drafts(%Workspace{} = source, %FileRef{} = file_ref, true) do
    case {source.project_view, file_ref} do
      {%ProjectView{} = view, %FileRef{kind: :path, relative_path: relative_path}}
      when is_binary(relative_path) ->
        safe_project_view_discard_file(view, relative_path)

      {nil, %FileRef{kind: :path}} ->
        {:error, "Workspace move failed: missing project view"}

      _ ->
        :ok
    end
  end

  defp maybe_discard_file_drafts(%Workspace{}, %FileRef{}, false), do: :ok

  @spec safe_project_view_discard_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  defp safe_project_view_discard_file(%ProjectView{} = view, relative_path) do
    safe_project_view_call(fn -> ProjectView.discard_file(view, relative_path) end)
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
  defp safe_project_view_call(fun) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:project_view_unavailable, reason}}
    end
  end

  @spec remove_source_file(Workspace.t(), FileRef.t(), boolean()) :: Workspace.t()
  defp remove_source_file(%Workspace{} = source, %FileRef{} = file_ref, true) do
    source
    |> Workspace.remove_file(file_ref)
    |> Workspace.set_review(WorkspaceReview.discard_file(source.review, file_ref))
  end

  defp remove_source_file(%Workspace{} = source, %FileRef{} = file_ref, false) do
    Workspace.remove_file(source, file_ref)
  end
end
