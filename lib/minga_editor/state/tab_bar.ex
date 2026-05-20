defmodule MingaEditor.State.TabBar do
  @moduledoc """
  Ordered list of open tabs with an active tab pointer.

  The tab bar is the primary navigation structure. Each tab (file or agent)
  carries a context snapshot of per-tab editor state. Buffer processes live
  in a shared pool, not inside individual tabs.

  ## Invariants

  - There is always at least one tab.
  - `active_id` always refers to an existing tab.
  - Tab ids are unique and monotonically increasing.
  """

  alias Minga.Buffer
  alias Minga.FileRef
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext

  @typedoc "Tab bar state."
  @type t :: %__MODULE__{
          tabs: [Tab.t()],
          active_id: Tab.id(),
          next_id: Tab.id(),
          workspaces: [Workspace.t()],
          next_workspace_id: pos_integer()
        }

  @enforce_keys [:tabs, :active_id, :next_id]
  defstruct tabs: [],
            active_id: 1,
            next_id: 2,
            workspaces: [],
            next_workspace_id: 1

  @doc "Creates a tab bar with a single initial tab and the manual workspace."
  @spec new(Tab.t(), String.t() | nil) :: t()
  def new(%Tab{} = tab, project_root \\ nil) do
    %__MODULE__{
      tabs: [tab],
      active_id: tab.id,
      next_id: tab.id + 1,
      workspaces: [Workspace.new_manual(project_root)]
    }
  end

  @doc "Returns the active tab."
  @spec active(t()) :: Tab.t() | nil
  def active(%__MODULE__{tabs: tabs, active_id: id}) do
    Enum.find(tabs, &(&1.id == id))
  end

  @doc "Returns the tab with the given id, or nil."
  @spec get(t(), Tab.id()) :: Tab.t() | nil
  def get(%__MODULE__{tabs: tabs}, id) do
    Enum.find(tabs, &(&1.id == id))
  end

  @doc "Returns the number of tabs."
  @spec count(t()) :: pos_integer()
  def count(%__MODULE__{tabs: tabs}), do: length(tabs)

  @doc "Returns the index of the active tab (0-based)."
  @spec active_index(t()) :: non_neg_integer()
  def active_index(%__MODULE__{tabs: tabs, active_id: id}) do
    Enum.find_index(tabs, &(&1.id == id)) || 0
  end

  @doc """
  Adds a new tab after the active tab and makes it active.

  Returns `{updated_tab_bar, new_tab}` so the caller can use the tab's id.
  """
  @spec add(t(), Tab.kind(), String.t()) :: {t(), Tab.t()}
  def add(%__MODULE__{} = tb, kind, label \\ "") do
    {tb, tab} = insert(tb, kind, label)
    {%{tb | active_id: tab.id}, tab}
  end

  @doc """
  Inserts a new tab next to the active tab without switching to it.

  Returns `{updated_tab_bar, new_tab}`. The caller is responsible for
  calling `switch_to/2` or `EditorState.switch_tab/2` to activate it.
  This is the primitive that `add/3` and `EditorState.add_buffer/2` build on.
  """
  @spec insert(t(), Tab.kind(), String.t()) :: {t(), Tab.t()}
  def insert(%__MODULE__{} = tb, kind, label \\ "") do
    tab =
      case kind do
        :file -> Tab.new_file(tb.next_id, label)
        :agent -> Tab.new_agent(tb.next_id, label)
      end

    active_idx = active_index(tb)
    {before, rest} = Enum.split(tb.tabs, active_idx + 1)
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    new_tabs = before ++ [tab] ++ rest

    {%{tb | tabs: new_tabs, next_id: tb.next_id + 1}, tab}
  end

  @doc """
  Removes the tab with the given id.

  If the removed tab was active, switches to the nearest neighbor (prefer
  right, then left). Returns `{:ok, updated_tab_bar}` or `:last_tab` if
  this is the only tab (can't remove the last one).
  """
  @spec remove(t(), Tab.id()) :: {:ok, t()} | :last_tab
  def remove(%__MODULE__{tabs: [_single]}, _id), do: :last_tab

  def remove(%__MODULE__{tabs: tabs, active_id: active_id} = tb, id) do
    idx = Enum.find_index(tabs, &(&1.id == id))

    case idx do
      nil ->
        {:ok, tb}

      _ ->
        new_tabs = List.delete_at(tabs, idx)

        new_active =
          if id == active_id do
            neighbor = Enum.at(new_tabs, min(idx, length(new_tabs) - 1))
            neighbor.id
          else
            active_id
          end

        {:ok, %{tb | tabs: new_tabs, active_id: new_active}}
    end
  end

  @doc "Keeps only the tab with the given id. Returns unchanged when the tab is not present."
  @spec keep_only(t(), Tab.id()) :: t()
  def keep_only(%__MODULE__{tabs: tabs} = tb, id) do
    case Enum.find(tabs, &(&1.id == id)) do
      nil -> tb
      tab -> keep_only_tab(tb, tab)
    end
  end

  @spec keep_only_tab(t(), Tab.t()) :: t()
  defp keep_only_tab(%__MODULE__{} = tb, %Tab{} = tab) do
    workspaces = workspaces_for_tabs(tb.workspaces, [tab])

    %{
      tb
      | tabs: [tab],
        active_id: tab.id,
        workspaces: preserve_manual_workspace(tb.workspaces, workspaces)
    }
  end

  @spec workspaces_for_tabs([Workspace.t()], [Tab.t()]) :: [Workspace.t()]
  defp workspaces_for_tabs(workspaces, tabs) do
    workspace_ids = tabs |> Enum.map(& &1.group_id) |> MapSet.new()
    Enum.filter(workspaces, &MapSet.member?(workspace_ids, &1.id))
  end

  @spec preserve_manual_workspace([Workspace.t()], [Workspace.t()]) :: [Workspace.t()]
  defp preserve_manual_workspace(all_workspaces, workspaces) do
    manual_workspace = Enum.find(all_workspaces, &(&1.id == 0)) || Workspace.new_manual(nil)
    agent_workspaces = Enum.reject(workspaces, &(&1.id == 0))
    [manual_workspace | agent_workspaces]
  end

  @doc "Returns true if a tab with the given id exists."
  @spec has_tab?(t(), Tab.id()) :: boolean()
  def has_tab?(%__MODULE__{tabs: tabs}, id) do
    Enum.any?(tabs, &(&1.id == id))
  end

  @doc "Returns the tab at the given 1-based position index, or nil."
  @spec tab_at(t(), pos_integer()) :: Tab.t() | nil
  def tab_at(%__MODULE__{tabs: tabs}, index) when index >= 1 do
    Enum.at(tabs, index - 1)
  end

  def tab_at(_, _), do: nil

  @doc "Updates the label of the tab with the given id."
  @spec update_label(t(), Tab.id(), String.t()) :: t()
  def update_label(%__MODULE__{tabs: tabs} = tb, id, label) do
    tabs =
      Enum.map(tabs, fn
        %{id: ^id} = tab -> %{tab | label: label}
        tab -> tab
      end)

    %{tb | tabs: tabs}
  end

  @doc "Switches the active tab to the one with the given id."
  @spec switch_to(t(), Tab.id()) :: t()
  def switch_to(%__MODULE__{tabs: tabs} = tb, id) do
    if Enum.any?(tabs, &(&1.id == id)) do
      %{tb | active_id: id}
    else
      tb
    end
  end

  @doc "Switches to the next visible file tab in the active workspace, wrapping around."
  @spec next(t()) :: t()
  def next(%__MODULE__{} = tb) do
    cycle_visible_file_tab(tb, 1)
  end

  @doc "Switches to the previous visible file tab in the active workspace, wrapping around."
  @spec prev(t()) :: t()
  def prev(%__MODULE__{} = tb) do
    cycle_visible_file_tab(tb, -1)
  end

  @doc "Updates the context of the tab with the given id."
  @spec update_context(t(), Tab.id(), Tab.context() | Tab.legacy_context()) :: t()
  def update_context(%__MODULE__{tabs: tabs} = tb, id, context) do
    new_tabs =
      Enum.map(tabs, fn
        %Tab{id: ^id} = tab -> Tab.set_context(tab, context)
        tab -> tab
      end)

    %{tb | tabs: new_tabs}
  end

  @doc "Returns the first tab matching the given kind, or nil."
  @spec find_by_kind(t(), Tab.kind()) :: Tab.t() | nil
  def find_by_kind(%__MODULE__{tabs: tabs}, kind) do
    Enum.find(tabs, &(&1.kind == kind))
  end

  @doc """
  Returns an agent tab that has no session assigned, or nil.

  Used by `start_agent_session` to find the correct tab to bind a
  new session to, avoiding ambiguity when multiple agent tabs exist.
  Falls back to the active tab if it's an agent tab.
  """
  @spec find_sessionless_agent(t()) :: Tab.t() | nil
  def find_sessionless_agent(%__MODULE__{tabs: tabs, active_id: active_id}) do
    # Prefer the active tab if it's an agent without a session.
    active = Enum.find(tabs, &(&1.id == active_id))

    if active && active.kind == :agent && active.session == nil do
      active
    else
      Enum.find(tabs, fn tab ->
        tab.kind == :agent and tab.session == nil
      end)
    end
  end

  @doc "Returns the agent tab whose session matches the given pid, or nil."
  @spec find_by_session(t(), pid()) :: Tab.t() | nil
  def find_by_session(%__MODULE__{tabs: tabs}, session_pid) when is_pid(session_pid) do
    Enum.find(tabs, fn
      %Tab{kind: :agent, session: ^session_pid} -> true
      _ -> false
    end)
  end

  @doc """
  Applies `fun` to the tab with `id`, replacing it in the list.

  Returns the updated tab bar. If no tab matches, returns unchanged.
  """
  @spec update_tab(t(), Tab.id(), (Tab.t() -> Tab.t())) :: t()
  def update_tab(%__MODULE__{tabs: tabs} = tb, id, fun) when is_function(fun, 1) do
    new_tabs =
      Enum.map(tabs, fn
        %Tab{id: ^id} = tab -> fun.(tab)
        tab -> tab
      end)

    %{tb | tabs: new_tabs}
  end

  @doc "Removes a dead buffer pid from all tab context snapshots."
  @spec scrub_dead_buffer(t(), pid()) :: t()
  def scrub_dead_buffer(%__MODULE__{tabs: tabs} = tb, pid) do
    %{tb | tabs: Enum.map(tabs, &Tab.scrub_buffer(&1, pid))}
  end

  @doc "Returns all tabs matching the given kind."
  @spec filter_by_kind(t(), Tab.kind()) :: [Tab.t()]
  def filter_by_kind(%__MODULE__{tabs: tabs}, kind) do
    Enum.filter(tabs, &(&1.kind == kind))
  end

  @doc """
  Returns the most recently used tab of the given kind that is NOT the
  active tab. Useful for "switch back to previous file/agent" commands.

  Tabs are searched right-to-left from the active position (wrapping), so
  the nearest neighbor of the requested kind is returned.
  """
  @spec most_recent_of_kind(t(), Tab.kind()) :: Tab.t() | nil
  def most_recent_of_kind(%__MODULE__{tabs: tabs, active_id: active_id}, kind) do
    tabs
    |> Enum.filter(&(&1.kind == kind and &1.id != active_id))
    |> List.last()
  end

  @doc """
  Cycles to the next tab of the given kind, wrapping around.
  If the active tab is already of that kind, jumps to the next one.
  If the active tab is a different kind, jumps to the first of the
  requested kind. Returns unchanged if no tabs of that kind exist.
  """
  @spec next_of_kind(t(), Tab.kind()) :: t()
  def next_of_kind(%__MODULE__{tabs: tabs, active_id: active_id} = tb, kind) do
    kind_tabs = Enum.filter(tabs, &(&1.kind == kind))

    case kind_tabs do
      [] ->
        tb

      [only] ->
        %{tb | active_id: only.id}

      _ ->
        current_idx = Enum.find_index(kind_tabs, &(&1.id == active_id))

        next_tab =
          case current_idx do
            nil -> hd(kind_tabs)
            idx -> Enum.at(kind_tabs, rem(idx + 1, length(kind_tabs)))
          end

        %{tb | active_id: next_tab.id}
    end
  end

  @doc "Returns true if any tab has its attention flag set."
  @spec any_attention?(t()) :: boolean()
  def any_attention?(%__MODULE__{tabs: tabs}) do
    Enum.any?(tabs, & &1.attention)
  end

  @doc "Returns the remote agent tab for a server/session id pair."
  @spec find_by_remote_session(t(), String.t(), String.t()) :: Tab.t() | nil
  def find_by_remote_session(%__MODULE__{tabs: tabs}, server_name, session_id)
      when is_binary(server_name) and is_binary(session_id) do
    Enum.find(tabs, fn
      %Tab{kind: :agent, server_name: ^server_name, remote_session_id: ^session_id} -> true
      _ -> false
    end)
  end

  @doc "Updates all tabs for a remote server to the given connection status."
  @spec set_remote_connection_status(t(), String.t(), Tab.connection_status()) :: t()
  def set_remote_connection_status(%__MODULE__{tabs: tabs} = tb, server_name, status)
      when is_binary(server_name) do
    new_tabs =
      Enum.map(tabs, fn
        %Tab{server_name: ^server_name} = tab -> Tab.set_connection_status(tab, status)
        tab -> tab
      end)

    %{tb | tabs: new_tabs}
  end

  @doc "Sets the attention flag on the tab matching the given session pid."
  @spec set_attention_by_session(t(), pid(), boolean()) :: t()
  def set_attention_by_session(%__MODULE__{} = tb, session_pid, value)
      when is_pid(session_pid) and is_boolean(value) do
    case find_by_session(tb, session_pid) do
      %Tab{id: id} -> update_tab(tb, id, &Tab.set_attention(&1, value))
      nil -> tb
    end
  end

  # ── Workspace management ───────────────────────────────────────────────────

  @doc "Returns all tabs belonging to the given workspace."
  @spec tabs_in_workspace(t(), non_neg_integer()) :: [Tab.t()]
  def tabs_in_workspace(%__MODULE__{tabs: tabs}, workspace_id) do
    Enum.filter(tabs, &(&1.group_id == workspace_id))
  end

  @doc "Returns the workspace with the given id, or nil."
  @spec get_workspace(t(), non_neg_integer()) :: Workspace.t() | nil
  def get_workspace(%__MODULE__{workspaces: workspaces}, id) do
    Enum.find(workspaces, &(&1.id == id))
  end

  @doc """
  Returns the active workspace.

  Derived from the active tab's group_id, not stored separately.
  The active workspace is always the workspace of the tab you're looking at.
  """
  @spec active_workspace(t()) :: Workspace.t() | nil
  def active_workspace(%__MODULE__{} = tb) do
    case active(tb) do
      %Tab{group_id: gid} -> get_workspace(tb, gid)
      nil -> get_workspace(tb, 0)
    end
  end

  @doc "Returns the active workspace id, derived from the active tab."
  @spec active_workspace_id(t()) :: non_neg_integer()
  def active_workspace_id(%__MODULE__{} = tb) do
    case active(tb) do
      %Tab{group_id: gid} -> gid
      nil -> 0
    end
  end

  @doc "Returns visible file tabs for the active workspace."
  @spec visible_file_tabs(t()) :: [Tab.t()]
  def visible_file_tabs(%__MODULE__{} = tb) do
    visible_file_tabs(tb, active_workspace_id(tb))
  end

  @doc "Returns visible file tabs for the given workspace id. Agent chat tabs are excluded."
  @spec visible_file_tabs(t(), non_neg_integer()) :: [Tab.t()]
  def visible_file_tabs(%__MODULE__{tabs: tabs}, workspace_id)
      when is_integer(workspace_id) and workspace_id >= 0 do
    Enum.filter(tabs, &visible_file_tab?(&1, workspace_id))
  end

  @doc "Finds the file tab in a workspace that represents the given file reference."
  @spec find_file_tab_in_workspace(t(), non_neg_integer(), FileRef.t()) :: Tab.t() | nil
  def find_file_tab_in_workspace(%__MODULE__{} = tb, workspace_id, %FileRef{} = file_ref)
      when is_integer(workspace_id) and workspace_id >= 0 do
    tb
    |> visible_file_tabs(workspace_id)
    |> Enum.find(&tab_matches_file_ref?(&1, file_ref))
  end

  @spec visible_file_tab?(Tab.t(), non_neg_integer()) :: boolean()
  defp visible_file_tab?(%Tab{kind: :file, group_id: workspace_id}, workspace_id), do: true
  defp visible_file_tab?(%Tab{}, _workspace_id), do: false

  @spec tab_matches_file_ref?(Tab.t(), FileRef.t()) :: boolean()
  defp tab_matches_file_ref?(%Tab{} = tab, %FileRef{} = file_ref) do
    case tab_file_ref(tab) do
      %FileRef{} = tab_ref -> FileRef.same?(tab_ref, file_ref)
      nil -> false
    end
  end

  @spec tab_file_ref(Tab.t()) :: FileRef.t() | nil
  defp tab_file_ref(%Tab{context: context}) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: pid}} when is_pid(pid) -> buffer_file_ref(pid)
      _ -> nil
    end
  end

  @spec buffer_file_ref(pid()) :: FileRef.t() | nil
  defp buffer_file_ref(pid) do
    case Buffer.file_path(pid) do
      path when is_binary(path) -> FileRef.new(path)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @spec cycle_visible_file_tab(t(), 1 | -1) :: t()
  defp cycle_visible_file_tab(%__MODULE__{} = tb, step) do
    case visible_file_tabs(tb) do
      [] -> tb
      [_single] -> tb
      tabs -> switch_to_cycle_neighbor(tb, tabs, step)
    end
  end

  @spec switch_to_cycle_neighbor(t(), [Tab.t()], 1 | -1) :: t()
  defp switch_to_cycle_neighbor(%__MODULE__{active_id: active_id} = tb, tabs, step) do
    idx = Enum.find_index(tabs, &(&1.id == active_id))
    target_idx = cycle_target_index(idx, length(tabs), step)
    %{tb | active_id: Enum.at(tabs, target_idx).id}
  end

  @spec cycle_target_index(non_neg_integer() | nil, pos_integer(), 1 | -1) :: non_neg_integer()
  defp cycle_target_index(nil, _len, 1), do: 0
  defp cycle_target_index(nil, len, -1), do: len - 1
  defp cycle_target_index(idx, len, 1), do: rem(idx + 1, len)
  defp cycle_target_index(0, len, -1), do: len - 1
  defp cycle_target_index(idx, _len, -1), do: idx - 1

  @doc """
  Adds an agent workspace and returns `{updated_tab_bar, workspace}`.

  The workspace is appended to the workspaces list. The `session` pid
  is stored so we can track which agent owns the workspace.
  """
  @spec add_workspace(t(), String.t(), pid() | nil) :: {t(), Workspace.t()}
  def add_workspace(%__MODULE__{} = tb, label, session \\ nil) do
    ws = Workspace.new_agent(tb.next_workspace_id, label, session)

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    workspaces = tb.workspaces ++ [ws]

    {%{tb | workspaces: workspaces, next_workspace_id: tb.next_workspace_id + 1}, ws}
  end

  @doc """
  Removes a workspace and migrates its tabs to the manual workspace (group_id 0).

  Cannot remove the manual workspace.
  """
  @spec remove_workspace(t(), non_neg_integer()) :: t()
  def remove_workspace(%__MODULE__{} = tb, 0), do: tb

  def remove_workspace(%__MODULE__{} = tb, workspace_id) do
    workspaces = Enum.reject(tb.workspaces, &(&1.id == workspace_id))

    tabs =
      Enum.map(tb.tabs, fn tab ->
        if tab.group_id == workspace_id, do: Tab.set_group(tab, 0), else: tab
      end)

    %{tb | workspaces: workspaces, tabs: tabs}
  end

  @doc "Moves a tab to a different workspace."
  @spec move_tab_to_workspace(t(), Tab.id(), non_neg_integer()) :: t()
  def move_tab_to_workspace(%__MODULE__{} = tb, tab_id, workspace_id) do
    update_tab(tb, tab_id, &Tab.set_group(&1, workspace_id))
  end

  @doc """
  Switches to the given workspace by activating its first tab.

  Returns unchanged if the workspace doesn't exist or has no tabs.
  """
  @spec switch_to_workspace(t(), non_neg_integer()) :: t()
  def switch_to_workspace(%__MODULE__{} = tb, workspace_id) do
    if Enum.any?(tb.workspaces, &(&1.id == workspace_id)) do
      switch_to_first_tab_in(tb, workspace_id)
    else
      tb
    end
  end

  @doc "Switches to the next agent workspace, wrapping around. No-op if no agent workspaces exist."
  @spec next_agent_workspace(t()) :: t()
  def next_agent_workspace(%__MODULE__{} = tb) do
    cycle_agent_workspace(tb, :next)
  end

  @doc "Switches to the previous agent workspace, wrapping around. No-op if no agent workspaces exist."
  @spec prev_agent_workspace(t()) :: t()
  def prev_agent_workspace(%__MODULE__{} = tb) do
    cycle_agent_workspace(tb, :prev)
  end

  @spec cycle_agent_workspace(t(), :next | :prev) :: t()
  defp cycle_agent_workspace(%__MODULE__{} = tb, direction) do
    case agent_workspaces(tb) do
      [] -> tb
      workspaces -> switch_to_cycled_agent_workspace(tb, workspaces, direction)
    end
  end

  @spec switch_to_cycled_agent_workspace(t(), [Workspace.t()], :next | :prev) :: t()
  defp switch_to_cycled_agent_workspace(tb, workspaces, :next) do
    current_id = active_workspace_id(tb)
    current_idx = Enum.find_index(workspaces, &(&1.id == current_id))

    next =
      case current_idx do
        nil -> hd(workspaces)
        idx -> Enum.at(workspaces, rem(idx + 1, length(workspaces)))
      end

    switch_to_first_tab_in(tb, next.id)
  end

  defp switch_to_cycled_agent_workspace(tb, workspaces, :prev) do
    current_id = active_workspace_id(tb)
    idx = Enum.find_index(workspaces, &(&1.id == current_id)) || 0
    len = length(workspaces)
    prev_idx = if idx == 0, do: len - 1, else: idx - 1
    prev = Enum.at(workspaces, prev_idx)
    switch_to_first_tab_in(tb, prev.id)
  end

  # Switches active_id to the first tab in the given workspace.
  # Returns unchanged if the workspace has no tabs.
  @spec switch_to_first_tab_in(t(), non_neg_integer()) :: t()
  defp switch_to_first_tab_in(tb, workspace_id) do
    case tabs_in_workspace(tb, workspace_id) do
      [first | _] -> %{tb | active_id: first.id}
      [] -> tb
    end
  end

  @doc "Returns the workspace matching the given session pid, or nil."
  @spec find_workspace_by_session(t(), pid()) :: Workspace.t() | nil
  def find_workspace_by_session(%__MODULE__{workspaces: workspaces}, session_pid)
      when is_pid(session_pid) do
    Enum.find(workspaces, fn
      %Workspace{session: ^session_pid} -> true
      _ -> false
    end)
  end

  @doc """
  Updates a workspace by applying `fun` to it.

  Returns unchanged tab bar if no workspace matches.
  """
  @spec update_workspace(t(), non_neg_integer(), (Workspace.t() -> Workspace.t())) :: t()
  def update_workspace(%__MODULE__{workspaces: workspaces} = tb, id, fun)
      when is_function(fun, 1) do
    new_workspaces =
      Enum.map(workspaces, fn
        %Workspace{id: ^id} = ws -> fun.(ws)
        ws -> ws
      end)

    %{tb | workspaces: new_workspaces}
  end

  @doc "Returns true if any agent workspaces exist."
  @spec has_agent_workspaces?(t()) :: boolean()
  def has_agent_workspaces?(%__MODULE__{} = tb) do
    agent_workspaces(tb) != []
  end

  @doc "Returns the progressive disclosure tier (0-3) based on agent workspace count."
  @spec disclosure_tier(t()) :: 0 | 1 | 2 | 3
  def disclosure_tier(%__MODULE__{} = tb) do
    agent_count = length(agent_workspaces(tb))

    case agent_count do
      0 -> 0
      1 -> 1
      n when n <= 4 -> 2
      _ -> 3
    end
  end

  @spec agent_workspaces(t()) :: [Workspace.t()]
  defp agent_workspaces(%__MODULE__{workspaces: workspaces}) do
    Enum.filter(workspaces, &(&1.kind == :agent))
  end
end
