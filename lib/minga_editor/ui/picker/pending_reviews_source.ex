defmodule MingaEditor.UI.Picker.PendingReviewsSource do
  @moduledoc """
  Picker source for workspaces awaiting review.

  The source snapshots review state at picker-open time. It lists conflicted work first, then review-ready drafts, with most recently active workspaces first within each state.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Persistence
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @pending_states [:conflict, :needs_review]

  @impl true
  @spec title() :: String.t()
  def title, do: "Pending reviews"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{tab_bar: %TabBar{} = tab_bar}) do
    tab_bar.workspaces
    |> Enum.filter(&pending_review?/1)
    |> Enum.map(&workspace_item/1)
    |> Enum.sort_by(&sort_key/1, :asc)
    |> empty_state_if_needed()
  end

  def candidates(_context), do: [empty_state_item()]

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: :empty}, state), do: state

  def on_select(
        %Item{id: {workspace_id, _last_activity}},
        %{shell_state: %{tab_bar: %TabBar{} = tab_bar}} = state
      ) do
    switch_to_workspace(state, tab_bar, workspace_id)
  end

  def on_select(_item, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec switch_to_workspace(term(), TabBar.t(), non_neg_integer()) :: term()
  defp switch_to_workspace(state, tab_bar, workspace_id) do
    case TabBar.tabs_in_workspace(tab_bar, workspace_id) do
      [] ->
        switch_to_restored_workspace(state, tab_bar, workspace_id)

      [_tab | _] ->
        EditorState.switch_tab(state, TabBar.switch_to_workspace(tab_bar, workspace_id).active_id)
    end
  end

  @spec switch_to_restored_workspace(term(), TabBar.t(), non_neg_integer()) :: term()
  defp switch_to_restored_workspace(state, tab_bar, workspace_id) do
    case TabBar.get_workspace(tab_bar, workspace_id) do
      %Workspace{} = workspace ->
        {tab_bar, tab} = TabBar.insert(tab_bar, :agent, workspace.label)
        tab_bar = TabBar.move_tab_to_workspace(tab_bar, tab.id, workspace_id)

        state
        |> EditorState.set_tab_bar(tab_bar)
        |> EditorState.switch_tab(tab.id)

      nil ->
        state
    end
  end

  @spec pending_review?(Workspace.t()) :: boolean()
  defp pending_review?(%Workspace{review: %WorkspaceReview{state: state}}),
    do: state in @pending_states

  defp pending_review?(%Workspace{}), do: false

  @spec workspace_item(Workspace.t()) :: Item.t()
  defp workspace_item(%Workspace{} = workspace) do
    activity = last_activity(workspace)
    review = workspace.review

    %Item{
      id: {workspace.id, activity.unix},
      label: workspace.label,
      description:
        "#{state_label(review.state)} • #{WorkspaceReview.draft_count(review)} draft file(s) • #{WorkspaceReview.conflict_count(review)} conflict file(s) • Last activity #{activity.label}",
      annotation: state_label(review.state),
      icon_color: workspace.color,
      two_line: true
    }
  end

  @spec sort_key(Item.t()) :: {non_neg_integer(), integer(), String.t()}
  defp sort_key(%Item{id: :empty}), do: {2, 0, ""}

  defp sort_key(%Item{id: {_workspace_id, last_activity}, annotation: state_label, label: label}) do
    {state_rank(state_label), -last_activity, label}
  end

  @spec state_rank(String.t() | nil) :: 0 | 1 | 2
  defp state_rank("Conflict"), do: 0
  defp state_rank("Needs review"), do: 1
  defp state_rank(_state), do: 2

  @spec state_label(WorkspaceReview.state()) :: String.t()
  defp state_label(:conflict), do: "Conflict"
  defp state_label(:needs_review), do: "Needs review"
  defp state_label(state), do: Atom.to_string(state)

  @spec last_activity(Workspace.t()) :: %{label: String.t(), unix: integer()}
  defp last_activity(%Workspace{project_root: project_root, id: id})
       when is_binary(project_root) do
    project_root
    |> Persistence.path_for(id)
    |> File.stat(time: :posix)
    |> activity_from_stat()
  end

  defp last_activity(%Workspace{}), do: %{label: "unknown", unix: 0}

  @spec activity_from_stat({:ok, File.Stat.t()} | {:error, term()}) :: %{
          label: String.t(),
          unix: integer()
        }
  defp activity_from_stat({:ok, %File.Stat{mtime: unix}}) when is_integer(unix) do
    %{label: format_unix(unix), unix: unix}
  end

  defp activity_from_stat(_result), do: %{label: "unknown", unix: 0}

  @spec format_unix(integer()) :: String.t()
  defp format_unix(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%b %d %H:%M")
  end

  @spec empty_state_if_needed([Item.t()]) :: [Item.t()]
  defp empty_state_if_needed([]), do: [empty_state_item()]
  defp empty_state_if_needed(items), do: items

  @spec empty_state_item() :: Item.t()
  defp empty_state_item do
    %Item{
      id: :empty,
      label: "No workspaces awaiting review",
      description: "All workspace drafts are clean or still in progress.",
      annotation: nil,
      two_line: true
    }
  end
end
