defmodule MingaEditor.WorkspaceWorkflow do
  @moduledoc """
  Persistence workflow for pure workspace and tab-bar transitions.

  Value owners calculate immutable transitions. This workflow compares their
  durable projections afterward and performs the corresponding writes and
  deletes outside those owners.
  """

  alias MingaAgent.ProjectView
  alias MingaEditor.Shell.Identity
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.StateStash
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Persistence

  @doc "Releases backend-owned resources for a workspace ProjectView."
  @spec close_project_view(Workspace.t()) :: :ok | {:error, term()}
  def close_project_view(%Workspace{project_view: %ProjectView{} = project_view}),
    do: ProjectView.close(project_view)

  def close_project_view(%Workspace{}), do: :ok

  @doc "Returns whether a workspace ProjectView backend is still available."
  @spec project_view_active?(Workspace.t()) :: boolean()
  def project_view_active?(%Workspace{project_view: %ProjectView{} = project_view}),
    do: ProjectView.active?(project_view)

  def project_view_active?(%Workspace{}), do: false

  @doc "Persists durable workspace changes between two Editor root values."
  @spec persist_changes(EditorState.t(), EditorState.t()) :: EditorState.t()
  def persist_changes(%EditorState{} = previous, %EditorState{} = current) do
    previous_bars = traditional_tab_bars(previous)
    current_bars = traditional_tab_bars(current)

    previous_bars
    |> Map.keys()
    |> Enum.filter(&Map.has_key?(current_bars, &1))
    |> Enum.each(fn identity ->
      persist_tab_bar_changes(
        Map.fetch!(previous_bars, identity),
        Map.fetch!(current_bars, identity)
      )
    end)

    current
  end

  @doc "Persists durable workspace changes between two pure tab-bar values."
  @spec persist_tab_bar_changes(TabBar.t() | nil, TabBar.t() | nil) :: :ok
  def persist_tab_bar_changes(%TabBar{} = previous, %TabBar{} = current) do
    previous_by_id = Map.new(previous.workspaces, &{&1.id, &1})
    current_by_id = Map.new(current.workspaces, &{&1.id, &1})

    Enum.each(current.workspaces, fn workspace ->
      persist_workspace_if_changed(Map.get(previous_by_id, workspace.id), workspace)
    end)

    Enum.each(previous.workspaces, fn workspace ->
      if not Map.has_key?(current_by_id, workspace.id) do
        _result = Persistence.delete(workspace.id, workspace.project_root)
      end
    end)

    :ok
  end

  def persist_tab_bar_changes(_previous, _current), do: :ok

  @doc "Auto-names and installs an already-selected Traditional workspace."
  @spec install_auto_named_workspace(EditorState.t(), non_neg_integer(), String.t()) ::
          EditorState.t()
  def install_auto_named_workspace(
        %EditorState{
          shell_runtime: %Runtime{
            entry: %{module: MingaEditor.Shell.Traditional},
            state: %TraditionalState{} = traditional
          }
        } = state,
        workspace_id,
        prompt
      )
      when is_integer(workspace_id) and workspace_id >= 0 and is_binary(prompt) do
    with %TabBar{} = tab_bar <- TraditionalState.tab_bar(traditional),
         %Workspace{} = workspace <- TabBar.get_workspace(tab_bar, workspace_id),
         %Workspace{} = updated_workspace <- Workspace.auto_name(workspace, prompt),
         false <- updated_workspace.label == workspace.label do
      install_tab_bar(state, TabBar.accept_workspace(tab_bar, updated_workspace))
    else
      _unchanged_or_missing -> state
    end
  end

  def install_auto_named_workspace(%EditorState{} = state, _workspace_id, _prompt), do: state

  @doc "Persists and installs an already-calculated Traditional tab bar."
  @spec install_tab_bar(EditorState.t(), TabBar.t()) :: EditorState.t()
  def install_tab_bar(
        %EditorState{
          shell_runtime: %Runtime{
            entry: %{module: MingaEditor.Shell.Traditional},
            state: %TraditionalState{} = traditional
          }
        } = state,
        %TabBar{} = tab_bar
      ) do
    previous = TraditionalState.tab_bar(traditional)
    :ok = persist_tab_bar_changes(previous, tab_bar)

    %EditorState{
      state
      | shell_runtime:
          Runtime.install_traditional_state(
            state.shell_runtime,
            TraditionalState.install_tab_bar(traditional, tab_bar)
          )
    }
  end

  def install_tab_bar(%EditorState{} = state, %TabBar{}), do: state

  @spec persist_workspace_if_changed(Workspace.t() | nil, Workspace.t()) :: :ok
  defp persist_workspace_if_changed(nil, %Workspace{} = workspace) do
    _result = Persistence.write(workspace, workspace.project_root)
    :ok
  end

  defp persist_workspace_if_changed(%Workspace{} = previous, %Workspace{} = current) do
    if Workspace.to_persisted_map(previous) != Workspace.to_persisted_map(current) do
      _result = Persistence.write(current, current.project_root)
    end

    :ok
  end

  @spec traditional_tab_bars(EditorState.t()) :: %{Identity.t() => TabBar.t() | nil}
  defp traditional_tab_bars(%EditorState{shell_runtime: %Runtime{} = runtime}) do
    runtime.stash
    |> Enum.reduce(active_traditional_tab_bar(runtime), fn
      {%Identity{} = identity,
       %StateStash{identity: stashed_identity, state: %TraditionalState{} = traditional}},
      acc
      when identity == stashed_identity ->
        Map.put(acc, identity, TraditionalState.tab_bar(traditional))

      {_identity, %StateStash{}}, acc ->
        acc
    end)
  end

  @spec active_traditional_tab_bar(Runtime.t()) :: %{Identity.t() => TabBar.t() | nil}
  defp active_traditional_tab_bar(
         %Runtime{
           entry: %{module: MingaEditor.Shell.Traditional},
           state: %TraditionalState{} = state
         } =
           runtime
       ) do
    %{Runtime.identity(runtime) => TraditionalState.tab_bar(state)}
  end

  defp active_traditional_tab_bar(%Runtime{}), do: %{}
end
