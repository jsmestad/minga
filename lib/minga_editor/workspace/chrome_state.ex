defmodule MingaEditor.Workspace.ChromeState do
  @moduledoc """
  Shared workspace chrome projection for GUI and TUI renderers.

  This module derives workspace-facing chrome state from the current editor state. It is a presentation projection, not storage. Frontends should consume this projection instead of inferring workspace membership from tab order, labels, paths, or agent status side effects.
  """

  alias Minga.Buffer
  alias Minga.Language
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Devicon
  alias MingaEditor.Workspace.ChromeState.TabSummary
  alias MingaEditor.Workspace.ChromeState.WorkspaceSummary

  @manual_workspace_id 0
  @manual_workspace_color 0

  @type mode :: :editor | :agent | :file_tree | :other

  @type t :: %__MODULE__{
          workspaces: [WorkspaceSummary.t()],
          visible_tabs: [TabSummary.t()],
          mode: mode(),
          active_workspace_id: non_neg_integer(),
          active_tab_id: Tab.id() | nil,
          background_count: non_neg_integer(),
          attention_count: non_neg_integer(),
          draft_count: non_neg_integer(),
          conflict_count: non_neg_integer()
        }

  @enforce_keys [
    :workspaces,
    :visible_tabs,
    :mode,
    :active_workspace_id,
    :active_tab_id,
    :background_count,
    :attention_count,
    :draft_count,
    :conflict_count
  ]
  defstruct @enforce_keys

  @doc "Builds the workspace chrome projection from current editor state."
  @spec from_editor_state(map()) :: t()
  def from_editor_state(state) do
    tb = tab_bar(state)
    active_workspace_id = active_workspace_id(tb)
    visible_tabs = visible_tabs(state, tb, active_workspace_id)
    workspaces = workspace_summaries(state, tb)

    %__MODULE__{
      workspaces: workspaces,
      visible_tabs: visible_tabs,
      mode: mode(state),
      active_workspace_id: active_workspace_id,
      active_tab_id: active_tab_id(tb),
      background_count: background_count(workspaces, active_workspace_id),
      attention_count: attention_count(workspaces),
      draft_count: total_draft_count(workspaces),
      conflict_count: total_conflict_count(workspaces)
    }
  end

  @doc "Returns the manual workspace id."
  @spec manual_workspace_id() :: non_neg_integer()
  def manual_workspace_id, do: @manual_workspace_id

  @doc "Returns the visible tabs for the active workspace."
  @spec visible_tabs(t()) :: [TabSummary.t()]
  def visible_tabs(%__MODULE__{visible_tabs: tabs}), do: tabs

  @spec tab_bar(map()) :: TabBar.t() | nil
  defp tab_bar(%{shell_state: %{tab_bar: %TabBar{} = tb}}), do: tb
  defp tab_bar(%{tab_bar: %TabBar{} = tb}), do: tb
  defp tab_bar(_state), do: nil

  @spec active_workspace_id(TabBar.t() | nil) :: non_neg_integer()
  defp active_workspace_id(%TabBar{} = tb), do: TabBar.active_workspace_id(tb)
  defp active_workspace_id(nil), do: @manual_workspace_id

  @spec active_tab_id(TabBar.t() | nil) :: Tab.id() | nil
  defp active_tab_id(%TabBar{active_id: id}), do: id
  defp active_tab_id(nil), do: nil

  @spec workspace_summaries(map(), TabBar.t() | nil) :: [WorkspaceSummary.t()]
  defp workspace_summaries(state, %TabBar{} = tb) do
    [manual_workspace_summary(state, tb) | agent_workspace_summaries(tb)]
  end

  defp workspace_summaries(state, nil), do: [manual_workspace_summary(state, nil)]

  @spec manual_workspace_summary(map(), TabBar.t() | nil) :: WorkspaceSummary.t()
  defp manual_workspace_summary(state, tb) do
    manual_workspace = tab_bar_manual_workspace(tb)
    manual_tabs = workspace_tabs(tb, @manual_workspace_id)

    WorkspaceSummary.new(
      id: @manual_workspace_id,
      kind: :manual,
      label: manual_workspace_label(state, manual_workspace),
      icon: manual_workspace_icon(manual_workspace),
      color: manual_workspace_color(manual_workspace),
      status: :idle,
      attention?: Enum.any?(manual_tabs, & &1.attention),
      tab_count: length(manual_tabs),
      draft_count: workspace_draft_count(manual_workspace),
      conflict_count: workspace_conflict_count(manual_workspace),
      running_background_count: 0,
      closeable?: false
    )
  end

  @spec tab_bar_manual_workspace(TabBar.t() | nil) :: Workspace.t() | nil
  defp tab_bar_manual_workspace(%TabBar{} = tb),
    do: TabBar.get_workspace(tb, @manual_workspace_id)

  defp tab_bar_manual_workspace(nil), do: nil

  @spec manual_workspace_label(map(), Workspace.t() | nil) :: String.t()
  defp manual_workspace_label(_state, %Workspace{custom_name: custom_name})
       when is_binary(custom_name) and custom_name != "" do
    custom_name
  end

  defp manual_workspace_label(%{workspace: %{custom_name: custom_name}}, _workspace)
       when is_binary(custom_name) and custom_name != "" do
    custom_name
  end

  defp manual_workspace_label(
         %{workspace: %{file_tree: %FileTreeState{project_root: root}}},
         _workspace
       ) do
    project_label(root)
  end

  defp manual_workspace_label(%{file_tree: %FileTreeState{project_root: root}}, _workspace) do
    project_label(root)
  end

  defp manual_workspace_label(_state, %Workspace{label: label})
       when is_binary(label) and label != "" do
    label
  end

  defp manual_workspace_label(_state, _workspace), do: "Files"

  @spec manual_workspace_icon(Workspace.t() | nil) :: String.t()
  defp manual_workspace_icon(%Workspace{icon: icon}) when is_binary(icon) and icon != "", do: icon
  defp manual_workspace_icon(_workspace), do: "folder"

  @spec manual_workspace_color(Workspace.t() | nil) :: non_neg_integer()
  defp manual_workspace_color(%Workspace{color: color}) when is_integer(color), do: color
  defp manual_workspace_color(_workspace), do: @manual_workspace_color

  @spec project_label(String.t() | nil) :: String.t()
  defp project_label(root) when is_binary(root) and root != "" do
    case Path.basename(root) do
      "" -> "Files"
      label -> label
    end
  end

  defp project_label(_root), do: "Files"

  @spec agent_workspace_summaries(TabBar.t()) :: [WorkspaceSummary.t()]
  defp agent_workspace_summaries(%TabBar{} = tb) do
    tb.workspaces
    |> Enum.filter(&(&1.kind == :agent))
    |> Enum.map(&agent_workspace_summary(tb, &1))
  end

  @spec agent_workspace_summary(TabBar.t(), Workspace.t()) :: WorkspaceSummary.t()
  defp agent_workspace_summary(%TabBar{} = tb, %Workspace{} = group) do
    tabs = workspace_tabs(tb, group.id)

    WorkspaceSummary.new(
      id: group.id,
      kind: :agent,
      label: group.label,
      icon: group.icon || "cpu",
      color: group.color,
      status: group.agent_status,
      attention?: Enum.any?(tabs, & &1.attention),
      tab_count: length(tabs),
      draft_count: workspace_draft_count(group),
      conflict_count: workspace_conflict_count(group),
      running_background_count: running_background_count(group),
      closeable?: true
    )
  end

  @spec total_draft_count([WorkspaceSummary.t()]) :: non_neg_integer()
  defp total_draft_count(workspaces) do
    Enum.reduce(workspaces, 0, &(&1.draft_count + &2))
  end

  @spec total_conflict_count([WorkspaceSummary.t()]) :: non_neg_integer()
  defp total_conflict_count(workspaces) do
    Enum.reduce(workspaces, 0, &(&1.conflict_count + &2))
  end

  @spec workspace_draft_count(Workspace.t() | nil) :: non_neg_integer()
  defp workspace_draft_count(%Workspace{review: %WorkspaceReview{} = review}),
    do: WorkspaceReview.draft_count(review)

  defp workspace_draft_count(_workspace), do: 0

  @spec workspace_conflict_count(Workspace.t() | nil) :: non_neg_integer()
  defp workspace_conflict_count(%Workspace{review: %WorkspaceReview{} = review}),
    do: WorkspaceReview.conflict_count(review)

  defp workspace_conflict_count(_workspace), do: 0

  @spec running_background_count(Workspace.t()) :: non_neg_integer()
  defp running_background_count(%Workspace{agent_status: status})
       when status in [:plan, :thinking, :tool_executing],
       do: 1

  defp running_background_count(%Workspace{}), do: 0

  @spec visible_tabs(map(), TabBar.t() | nil, non_neg_integer()) :: [TabSummary.t()]
  defp visible_tabs(_state, nil, _active_workspace_id), do: []

  defp visible_tabs(state, %TabBar{} = tb, active_workspace_id) do
    tb
    |> workspace_tabs(active_workspace_id)
    |> Enum.filter(&(&1.kind == :file))
    |> Enum.map(&tab_summary(state, &1, active_workspace_id))
  end

  @spec workspace_tabs(TabBar.t() | nil, non_neg_integer()) :: [Tab.t()]
  defp workspace_tabs(%TabBar{} = tb, workspace_id),
    do: TabBar.tabs_in_workspace(tb, workspace_id)

  defp workspace_tabs(nil, _workspace_id), do: []

  @spec tab_summary(map(), Tab.t(), non_neg_integer()) :: TabSummary.t()
  defp tab_summary(state, %Tab{} = tab, workspace_id) do
    buffer = tab_buffer(state, tab)
    path = buffer_path(buffer)

    TabSummary.new(
      id: tab.id,
      workspace_id: workspace_id,
      kind: tab.kind,
      label: Tab.display_label(tab),
      path: path,
      icon: tab_icon(tab, path),
      dirty?: buffer_dirty?(buffer),
      draft_state: :none,
      attention?: tab.attention
    )
  end

  @spec tab_buffer(map(), Tab.t()) :: pid() | nil
  defp tab_buffer(state, %Tab{id: id, context: context}) do
    if id == active_tab_id(tab_bar(state)) do
      active_state_buffer(state) || context_buffer(context)
    else
      context_buffer(context)
    end
  end

  @spec active_state_buffer(map()) :: pid() | nil
  defp active_state_buffer(%{workspace: %{buffers: %Buffers{active: buf}}}) when is_pid(buf) do
    if Process.alive?(buf), do: buf, else: nil
  end

  defp active_state_buffer(%{buffers: %Buffers{active: buf}}) when is_pid(buf) do
    if Process.alive?(buf), do: buf, else: nil
  end

  defp active_state_buffer(_state), do: nil

  @spec context_buffer(Tab.context() | Tab.legacy_context()) :: pid() | nil
  defp context_buffer(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: buf}} when is_pid(buf) -> buf
      _ -> nil
    end
  end

  @spec buffer_path(pid() | nil) :: String.t() | nil
  defp buffer_path(pid) when is_pid(pid) do
    Buffer.file_path(pid)
  catch
    :exit, _ -> nil
  end

  defp buffer_path(_pid), do: nil

  @spec buffer_dirty?(pid() | nil) :: boolean()
  defp buffer_dirty?(pid) when is_pid(pid) do
    Buffer.dirty?(pid)
  catch
    :exit, _ -> false
  end

  defp buffer_dirty?(_pid), do: false

  @spec tab_icon(Tab.t(), String.t() | nil) :: String.t()
  defp tab_icon(%Tab{kind: :agent}, _path), do: Devicon.icon(:agent)

  defp tab_icon(%Tab{kind: :file, label: label}, path) do
    source = path || label
    Devicon.icon(Language.detect_filetype(source))
  end

  @spec mode(map()) :: mode()
  defp mode(%{workspace: %{keymap_scope: scope}}), do: mode_from_scope(scope)
  defp mode(%{keymap_scope: scope}), do: mode_from_scope(scope)
  defp mode(_state), do: :editor

  @spec mode_from_scope(atom()) :: mode()
  defp mode_from_scope(:agent), do: :agent
  defp mode_from_scope(:file_tree), do: :file_tree
  defp mode_from_scope(:editor), do: :editor
  defp mode_from_scope(_scope), do: :other

  @spec background_count([WorkspaceSummary.t()], non_neg_integer()) :: non_neg_integer()
  defp background_count(workspaces, active_workspace_id) do
    Enum.count(workspaces, &(&1.id != active_workspace_id and &1.running_background_count > 0))
  end

  @spec attention_count([WorkspaceSummary.t()]) :: non_neg_integer()
  defp attention_count(workspaces) do
    Enum.count(workspaces, & &1.attention?)
  end
end
