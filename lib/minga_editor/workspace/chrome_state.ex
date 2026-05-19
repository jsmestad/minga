defmodule MingaEditor.Workspace.ChromeState do
  @moduledoc """
  Shared workspace chrome projection for GUI and TUI renderers.

  This module derives workspace-facing chrome state from the current editor state. It is a presentation projection, not storage. Frontends should consume this projection instead of inferring workspace membership from tab order, labels, paths, or agent status side effects.
  """

  alias Minga.Buffer
  alias Minga.Language
  alias MingaEditor.State.AgentGroup
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
      draft_count: 0,
      conflict_count: 0
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
  defp active_workspace_id(%TabBar{} = tb), do: TabBar.active_group_id(tb)
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
    manual_tabs = workspace_tabs(tb, @manual_workspace_id)

    WorkspaceSummary.new(
      id: @manual_workspace_id,
      kind: :manual,
      label: manual_workspace_label(state),
      icon: "folder",
      color: @manual_workspace_color,
      status: :idle,
      attention?: Enum.any?(manual_tabs, & &1.attention),
      tab_count: length(manual_tabs),
      draft_count: 0,
      conflict_count: 0,
      running_background_count: 0,
      closeable?: false
    )
  end

  @spec manual_workspace_label(map()) :: String.t()
  defp manual_workspace_label(%{workspace: %{custom_name: custom_name}})
       when is_binary(custom_name) and custom_name != "" do
    custom_name
  end

  defp manual_workspace_label(%{workspace: %{file_tree: %FileTreeState{project_root: root}}}) do
    project_label(root)
  end

  defp manual_workspace_label(%{file_tree: %FileTreeState{project_root: root}}) do
    project_label(root)
  end

  defp manual_workspace_label(_state), do: "Files"

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
    Enum.map(tb.agent_groups, &agent_workspace_summary(tb, &1))
  end

  @spec agent_workspace_summary(TabBar.t(), AgentGroup.t()) :: WorkspaceSummary.t()
  defp agent_workspace_summary(%TabBar{} = tb, %AgentGroup{} = group) do
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
      draft_count: 0,
      conflict_count: 0,
      running_background_count: running_background_count(group),
      closeable?: true
    )
  end

  @spec running_background_count(AgentGroup.t()) :: non_neg_integer()
  defp running_background_count(%AgentGroup{agent_status: status})
       when status in [:plan, :thinking, :tool_executing],
       do: 1

  defp running_background_count(%AgentGroup{}), do: 0

  @spec visible_tabs(map(), TabBar.t() | nil, non_neg_integer()) :: [TabSummary.t()]
  defp visible_tabs(_state, nil, _active_workspace_id), do: []

  defp visible_tabs(state, %TabBar{} = tb, active_workspace_id) do
    tb
    |> workspace_tabs(active_workspace_id)
    |> Enum.filter(&(&1.kind == :file))
    |> Enum.map(&tab_summary(state, &1, active_workspace_id))
  end

  @spec workspace_tabs(TabBar.t() | nil, non_neg_integer()) :: [Tab.t()]
  defp workspace_tabs(%TabBar{} = tb, workspace_id), do: TabBar.tabs_in_group(tb, workspace_id)
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
