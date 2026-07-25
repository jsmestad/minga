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

  alias Minga.Project.FileRef
  alias MingaEditor.FeatureState
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent

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

  @doc """
  Creates a tab bar with no tabs, for a zero-buffers launchpad startup (#2689).

  `active_id` keeps its dangling default (1) — `active/1` returns nil for an
  empty bar — so `next_id` starts at 2 to guarantee no restored or added tab
  ever collides with the dangling active id.
  """
  @spec new_empty(String.t() | nil) :: t()
  def new_empty(project_root \\ nil) do
    %__MODULE__{
      tabs: [],
      active_id: 1,
      next_id: 2,
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
  Removes every file tab, leaving agent tabs (if any) in place.

  Used when the workspace enters the zero-buffers launchpad (#2689): the
  file tab strip collapses instead of keeping phantom tabs. `remove/2`
  keeps its can't-remove-last contract for every other caller. When the
  active tab was removed, the first remaining tab becomes active;
  `active/1` tolerates an empty bar (returns nil).
  """
  @spec remove_file_tabs(t()) :: t()
  def remove_file_tabs(%__MODULE__{tabs: tabs, active_id: active_id} = tb) do
    remaining = Enum.reject(tabs, &(&1.kind == :file))

    new_active =
      case {Enum.find(remaining, &(&1.id == active_id)), remaining} do
        {%Tab{}, _} -> active_id
        {nil, [%Tab{id: first_id} | _]} -> first_id
        {nil, []} -> active_id
      end

    %{tb | tabs: remaining, active_id: new_active}
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

  @doc "Snapshots the outgoing tab and activates an existing target tab atomically."
  @spec snapshot_and_switch(t(), Tab.id(), Tab.context(), Tab.id()) :: t()
  def snapshot_and_switch(%__MODULE__{} = tab_bar, current_id, context, target_id) do
    if has_tab?(tab_bar, target_id) do
      tab_bar
      |> update_context(current_id, context)
      |> switch_to(target_id)
    else
      tab_bar
    end
  end

  @doc "Records attention for the identified tab without changing tab identity or order."
  @spec set_tab_attention(t(), Tab.id(), boolean()) :: t()
  def set_tab_attention(%__MODULE__{} = tab_bar, tab_id, attention?)
      when is_boolean(attention?) do
    replace_matching_tab(tab_bar, tab_id, &Tab.set_attention(&1, attention?))
  end

  @doc "Clears attention for the identified tab without changing tab identity or order."
  @spec clear_attention(t(), Tab.id()) :: t()
  def clear_attention(%__MODULE__{} = tab_bar, tab_id) do
    set_tab_attention(tab_bar, tab_id, false)
  end

  @doc "Rebinds every matching file tab and workspace reference to one logical file identity."
  @spec rebind_buffer_file(t(), pid(), FileRef.t()) :: t()
  def rebind_buffer_file(%__MODULE__{} = tab_bar, buffer_pid, %FileRef{} = file_ref)
      when is_pid(buffer_pid) do
    matching_tabs = Enum.filter(tab_bar.tabs, &tab_matches_buffer?(&1, buffer_pid))

    Enum.reduce(matching_tabs, tab_bar, fn %Tab{} = tab, acc ->
      acc
      |> replace_matching_tab(tab.id, &Tab.set_file_ref(&1, file_ref))
      |> retarget_matching_workspace(tab, file_ref)
    end)
  end

  @doc "Returns every live buffer pid represented by tab snapshots."
  @spec buffer_pids(t()) :: [pid()]
  def buffer_pids(%__MODULE__{tabs: tabs}) do
    tabs
    |> Enum.flat_map(&TabContext.buffer_pids(&1.context))
    |> Enum.uniq()
  end

  @doc "Clears replayed catch-up events for the identified workspace."
  @spec clear_workspace_catchup_events(t(), non_neg_integer()) :: t()
  def clear_workspace_catchup_events(%__MODULE__{} = tab_bar, workspace_id) do
    replace_matching_workspace(tab_bar, workspace_id, &Workspace.clear_pending_catchup_events/1)
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

  @spec replace_matching_tab(t(), Tab.id(), (Tab.t() -> Tab.t())) :: t()
  defp replace_matching_tab(%__MODULE__{tabs: tabs} = tab_bar, tab_id, transition) do
    tabs =
      Enum.map(tabs, fn
        %Tab{id: ^tab_id} = tab -> transition.(tab)
        tab -> tab
      end)

    %{tab_bar | tabs: tabs}
  end

  @spec tab_matches_buffer?(Tab.t(), pid()) :: boolean()
  defp tab_matches_buffer?(
         %Tab{kind: :file, file_ref: %FileRef{kind: :buffer, buffer_pid: buffer_pid}},
         buffer_pid
       ),
       do: true

  defp tab_matches_buffer?(%Tab{kind: :file, context: context}, buffer_pid) do
    TabContext.active_buffer_pid(context) == buffer_pid
  end

  defp tab_matches_buffer?(%Tab{}, _buffer_pid), do: false

  @spec retarget_matching_workspace(t(), Tab.t(), FileRef.t()) :: t()
  defp retarget_matching_workspace(
         %__MODULE__{} = tab_bar,
         %Tab{group_id: workspace_id, file_ref: old_file_ref},
         %FileRef{} = file_ref
       ) do
    replace_matching_workspace(tab_bar, workspace_id, fn workspace ->
      Workspace.retarget_file(workspace, old_file_ref, file_ref)
    end)
  end

  @doc "Accepts a concrete tab only at its existing stable identity."
  @spec accept_tab(t(), Tab.t()) :: t()
  def accept_tab(%__MODULE__{} = tab_bar, %Tab{id: tab_id} = accepted) do
    replace_matching_tab(tab_bar, tab_id, fn _current -> accepted end)
  end

  @doc "Records an agent status on the identified tab."
  @spec set_tab_agent_status(t(), Tab.id(), Tab.agent_status()) :: t()
  def set_tab_agent_status(%__MODULE__{} = tab_bar, tab_id, status) do
    replace_matching_tab(tab_bar, tab_id, &Tab.set_agent_status(&1, status))
  end

  @doc "Binds or clears the session owned by the identified tab."
  @spec set_tab_session(t(), Tab.id(), pid() | nil) :: t()
  def set_tab_session(%__MODULE__{} = tab_bar, tab_id, session) do
    replace_matching_tab(tab_bar, tab_id, &Tab.set_session(&1, session))
  end

  @doc "Refreshes a restarted session identity and status on the identified tab."
  @spec refresh_tab_session(t(), Tab.id(), pid(), pid(), Tab.agent_status()) :: t()
  def refresh_tab_session(%__MODULE__{} = tab_bar, tab_id, old_pid, new_pid, status) do
    replace_matching_tab(tab_bar, tab_id, fn tab ->
      tab = Tab.refresh_session_pid(tab, old_pid, new_pid)
      if is_nil(status), do: tab, else: Tab.set_agent_status(tab, status)
    end)
  end

  @doc "Records a remote session identity on the identified tab."
  @spec set_tab_remote_session(t(), Tab.id(), String.t(), String.t(), pid()) :: t()
  def set_tab_remote_session(tab_bar, tab_id, server_name, session_id, remote_pid) do
    replace_matching_tab(tab_bar, tab_id, fn tab ->
      Tab.set_remote_session(tab, server_name, session_id, remote_pid)
    end)
  end

  @doc "Records remote connection status on the identified tab."
  @spec set_tab_connection_status(t(), Tab.id(), Tab.connection_status()) :: t()
  def set_tab_connection_status(tab_bar, tab_id, status) do
    replace_matching_tab(tab_bar, tab_id, &Tab.set_connection_status(&1, status))
  end

  @doc "Retargets one tab and its workspace to a concrete file identity."
  @spec retarget_tab_file(t(), Tab.id(), FileRef.t()) :: t()
  def retarget_tab_file(%__MODULE__{} = tab_bar, tab_id, %FileRef{} = file_ref) do
    case get(tab_bar, tab_id) do
      %Tab{} = tab ->
        tab_bar
        |> replace_matching_tab(tab_id, &Tab.set_file_ref(&1, file_ref))
        |> retarget_matching_workspace(tab, file_ref)

      nil ->
        tab_bar
    end
  end

  @doc "Pins the tab with the given id. Returns unchanged when the tab is missing."
  @spec pin_tab(t(), Tab.id()) :: t()
  def pin_tab(%__MODULE__{} = tb, id) do
    replace_matching_tab(tb, id, &Tab.set_pinned(&1, true))
  end

  @doc "Unpins the tab with the given id. Returns unchanged when the tab is missing."
  @spec unpin_tab(t(), Tab.id()) :: t()
  def unpin_tab(%__MODULE__{} = tb, id) do
    replace_matching_tab(tb, id, &Tab.set_pinned(&1, false))
  end

  @doc "Toggles the pinned state of the active tab."
  @spec toggle_active_pin(t()) :: t()
  def toggle_active_pin(%__MODULE__{active_id: id} = tb) do
    replace_matching_tab(tb, id, &Tab.toggle_pinned/1)
  end

  @doc "Moves the active tab one visible slot left within its workspace."
  @spec move_active_tab_left(t()) :: t()
  def move_active_tab_left(%__MODULE__{} = tb), do: move_tab(tb, tb.active_id, -1)

  @doc "Moves the active tab one visible slot right within its workspace."
  @spec move_active_tab_right(t()) :: t()
  def move_active_tab_right(%__MODULE__{} = tb), do: move_tab(tb, tb.active_id, 1)

  @doc "Moves the tab with the given id one visible slot left within its workspace."
  @spec move_tab_left(t(), Tab.id()) :: t()
  def move_tab_left(%__MODULE__{} = tb, id), do: move_tab(tb, id, -1)

  @doc "Moves the tab with the given id one visible slot right within its workspace."
  @spec move_tab_right(t(), Tab.id()) :: t()
  def move_tab_right(%__MODULE__{} = tb, id), do: move_tab(tb, id, 1)

  @doc "Reorders a visible file tab within its workspace by zero-based visible index."
  @spec reorder_tab(t(), Tab.id(), non_neg_integer()) :: t()
  def reorder_tab(%__MODULE__{} = tb, id, new_index)
      when is_integer(new_index) and new_index >= 0 do
    case get(tb, id) do
      %Tab{kind: :file, group_id: workspace_id} ->
        reorder_file_tab(tb, id, workspace_id, new_index)

      _ ->
        tb
    end
  end

  @doc "Removes a dead buffer pid from every tab and workspace projection."
  @spec scrub_dead_buffer(t(), pid()) :: t()
  def scrub_dead_buffer(%__MODULE__{tabs: tabs, workspaces: workspaces} = tb, pid)
      when is_pid(pid) do
    %{
      tb
      | tabs: Enum.map(tabs, &Tab.scrub_buffer(&1, pid)),
        workspaces: Enum.map(workspaces, &Workspace.retire_buffer(&1, pid))
    }
  end

  def scrub_dead_buffer(%__MODULE__{} = tb, _pid), do: tb

  @doc "Drops snapshotted feature state owned by a source from every tab context."
  @spec drop_feature_state_source(t(), FeatureState.source()) :: t()
  def drop_feature_state_source(%__MODULE__{tabs: tabs} = tb, source) do
    %{tb | tabs: Enum.map(tabs, &Tab.drop_feature_state_source(&1, source))}
  end

  @doc "Drops snapshotted extension-owned feature state from every tab context."
  @spec drop_extension_feature_state_sources(t()) :: t()
  def drop_extension_feature_state_sources(%__MODULE__{tabs: tabs} = tb) do
    %{tb | tabs: Enum.map(tabs, &Tab.drop_extension_feature_state_sources/1)}
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
    |> Enum.at(-1)
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

  @doc "Returns the workspace matching a remote server/session id pair."
  @spec find_workspace_by_remote_session(t(), String.t(), String.t()) :: Workspace.t() | nil
  def find_workspace_by_remote_session(
        %__MODULE__{workspaces: workspaces},
        server_name,
        session_id
      )
      when is_binary(server_name) and is_binary(session_id) do
    Enum.find(workspaces, &Workspace.matches_remote_session?(&1, server_name, session_id))
  end

  @doc "Returns remote workspaces for a server."
  @spec remote_workspaces_for_server(t(), String.t()) :: [Workspace.t()]
  def remote_workspaces_for_server(%__MODULE__{workspaces: workspaces}, server_name)
      when is_binary(server_name) do
    Enum.filter(workspaces, &Workspace.remote_server?(&1, server_name))
  end

  @doc "Updates all workspaces and projected tabs for a remote server to the given connection status."
  @spec set_remote_connection_status(t(), String.t(), Tab.connection_status()) :: t()
  def set_remote_connection_status(%__MODULE__{} = tb, server_name, status)
      when is_binary(server_name) and status in [:connected, :disconnected, :ended, :unavailable] do
    tb
    |> set_server_workspace_connection_status(server_name, status)
    |> set_projected_tab_remote_connection_status(server_name, status)
  end

  @spec set_server_workspace_connection_status(t(), String.t(), Workspace.connection_status()) ::
          t()
  defp set_server_workspace_connection_status(%__MODULE__{} = tb, server_name, status) do
    Enum.reduce(remote_workspaces_for_server(tb, server_name), tb, fn %Workspace{id: id}, acc ->
      replace_matching_workspace(acc, id, &Workspace.set_remote_connection_status(&1, status))
    end)
  end

  @spec set_projected_tab_remote_connection_status(t(), String.t(), Tab.connection_status()) ::
          t()
  defp set_projected_tab_remote_connection_status(
         %__MODULE__{tabs: tabs} = tb,
         server_name,
         status
       ) do
    new_tabs =
      Enum.map(tabs, fn
        %Tab{server_name: ^server_name} = tab -> Tab.set_connection_status(tab, status)
        tab -> tab
      end)

    %{tb | tabs: new_tabs}
  end

  @doc "Synchronizes any agent-tab projection from workspace-owned lifecycle and remote metadata."
  @spec sync_workspace_agent_tab_projection(t(), non_neg_integer()) :: t()
  def sync_workspace_agent_tab_projection(%__MODULE__{} = tb, workspace_id)
      when is_integer(workspace_id) do
    case get_workspace(tb, workspace_id) do
      %Workspace{} = workspace -> sync_workspace_agent_tab_projection(tb, workspace)
      nil -> tb
    end
  end

  @spec sync_workspace_agent_tab_projection(t(), Workspace.agent() | Workspace.manual()) :: t()
  def sync_workspace_agent_tab_projection(%__MODULE__{} = tb, %Workspace{
        payload: %Workspace.Manual{}
      }),
      do: tb

  def sync_workspace_agent_tab_projection(
        %__MODULE__{tabs: tabs} = tb,
        %Workspace{
          payload: %WorkspaceAgent{}
        } = workspace
      ) do
    new_tabs =
      Enum.map(tabs, fn
        %Tab{kind: :agent, group_id: workspace_id} = tab when workspace_id == workspace.id ->
          project_workspace_onto_agent_tab(tab, workspace)

        tab ->
          tab
      end)

    %{tb | tabs: new_tabs}
  end

  @spec project_workspace_onto_agent_tab(Tab.t(), Workspace.agent()) :: Tab.t()
  defp project_workspace_onto_agent_tab(%Tab{} = tab, %Workspace{
         payload: %WorkspaceAgent{} = payload
       }) do
    tab = Tab.set_session(tab, payload.session)
    tab = Tab.set_agent_status(tab, payload.agent_status)

    case payload.remote_session do
      %MingaEditor.State.Workspace.RemoteSession{} = remote_session ->
        Tab.set_remote_projection(tab, remote_session)

      nil ->
        Tab.clear_remote_projection(tab)
    end
  end

  @doc "Sets the attention flag on the tab matching the given session pid."
  @spec set_attention_by_session(t(), pid(), boolean()) :: t()
  def set_attention_by_session(%__MODULE__{} = tb, session_pid, value)
      when is_pid(session_pid) and is_boolean(value) do
    case find_by_session(tb, session_pid) do
      %Tab{id: id} -> replace_matching_tab(tb, id, &Tab.set_attention(&1, value))
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

  @doc "Returns visible content tabs for the active workspace."
  @spec visible_workspace_tabs(t()) :: [Tab.t()]
  def visible_workspace_tabs(%__MODULE__{} = tb) do
    visible_workspace_tabs(tb, active_workspace_id(tb))
  end

  @doc "Returns visible content tabs for the given workspace id. Agent workspaces show their agent tab first, followed by file tabs."
  @spec visible_workspace_tabs(t(), non_neg_integer()) :: [Tab.t()]
  def visible_workspace_tabs(%__MODULE__{} = tb, workspace_id)
      when is_integer(workspace_id) and workspace_id >= 0 do
    case get_workspace(tb, workspace_id) do
      %Workspace{kind: :agent} ->
        visible_agent_tabs(tb, workspace_id) ++ visible_file_tabs(tb, workspace_id)

      _workspace ->
        visible_file_tabs(tb, workspace_id)
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
    tabs
    |> Enum.filter(&visible_file_tab?(&1, workspace_id))
    |> pinned_first()
  end

  @spec visible_agent_tabs(t(), non_neg_integer()) :: [Tab.t()]
  defp visible_agent_tabs(%__MODULE__{tabs: tabs}, workspace_id) do
    Enum.filter(tabs, &visible_agent_tab?(&1, workspace_id))
  end

  @spec visible_agent_tab?(Tab.t(), non_neg_integer()) :: boolean()
  defp visible_agent_tab?(%Tab{kind: :agent, group_id: workspace_id}, workspace_id), do: true
  defp visible_agent_tab?(%Tab{}, _workspace_id), do: false

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

  @spec pinned_first([Tab.t()]) :: [Tab.t()]
  defp pinned_first(tabs) do
    Enum.filter(tabs, & &1.pinned?) ++ Enum.reject(tabs, & &1.pinned?)
  end

  @spec move_tab(t(), Tab.id(), 1 | -1) :: t()
  defp move_tab(%__MODULE__{} = tb, id, step) do
    case get(tb, id) do
      %Tab{kind: :file, group_id: workspace_id} ->
        move_file_tab(tb, id, workspace_id, step)

      _ ->
        tb
    end
  end

  @spec move_file_tab(t(), Tab.id(), non_neg_integer(), 1 | -1) :: t()
  defp move_file_tab(%__MODULE__{} = tb, id, workspace_id, step) do
    tabs = visible_file_tabs(tb, workspace_id)

    case Enum.find_index(tabs, &(&1.id == id)) do
      nil ->
        tb

      current_index ->
        target_index = current_index + step

        if visible_tab_reorder_allowed?(tabs, current_index, target_index) do
          reorder_tab(tb, id, target_index)
        else
          tb
        end
    end
  end

  @spec reorder_file_tab(t(), Tab.id(), non_neg_integer(), non_neg_integer()) :: t()
  defp reorder_file_tab(%__MODULE__{} = tb, id, workspace_id, new_index) do
    tabs = visible_file_tabs(tb, workspace_id)
    current_index = Enum.find_index(tabs, &(&1.id == id))

    if visible_tab_reorder_allowed?(tabs, current_index, new_index) do
      reorder_visible_file_tab(tb, workspace_id, tabs, current_index, new_index)
    else
      tb
    end
  end

  @spec visible_tab_reorder_allowed?([Tab.t()], non_neg_integer() | nil, non_neg_integer()) ::
          boolean()
  defp visible_tab_reorder_allowed?(_tabs, nil, _target_index), do: false

  defp visible_tab_reorder_allowed?(tabs, current_index, target_index) do
    target_index >= 0 and target_index < length(tabs) and
      same_visible_bucket?(tabs, current_index, target_index)
  end

  @spec same_visible_bucket?([Tab.t()], non_neg_integer(), non_neg_integer()) :: boolean()
  defp same_visible_bucket?(tabs, current_index, target_index) do
    pinned_count = Enum.count(tabs, & &1.pinned?)

    visible_bucket(current_index, pinned_count) ==
      visible_bucket(target_index, pinned_count)
  end

  @spec visible_bucket(non_neg_integer(), non_neg_integer()) :: :pinned | :unpinned
  defp visible_bucket(index, pinned_count) when index < pinned_count, do: :pinned
  defp visible_bucket(_index, _pinned_count), do: :unpinned

  @spec reorder_visible_file_tab(
          t(),
          non_neg_integer(),
          [Tab.t()],
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  defp reorder_visible_file_tab(tb, _workspace_id, [_single], _current_index, _new_index), do: tb

  defp reorder_visible_file_tab(tb, workspace_id, tabs, current_index, new_index) do
    {tab, remaining} = List.pop_at(tabs, current_index)
    reordered = List.insert_at(remaining, new_index, tab)
    replace_visible_file_tabs(tb, workspace_id, reordered)
  end

  @spec replace_visible_file_tabs(t(), non_neg_integer(), [Tab.t()]) :: t()
  defp replace_visible_file_tabs(%__MODULE__{tabs: tabs} = tb, workspace_id, replacements) do
    {new_tabs, _remaining} =
      Enum.map_reduce(tabs, replacements, &replace_visible_file_tab(&1, &2, workspace_id))

    %{tb | tabs: new_tabs}
  end

  @spec replace_visible_file_tab(Tab.t(), [Tab.t()], non_neg_integer()) :: {Tab.t(), [Tab.t()]}
  defp replace_visible_file_tab(
         %Tab{kind: :file, group_id: workspace_id},
         [next | rest],
         workspace_id
       ),
       do: {next, rest}

  defp replace_visible_file_tab(tab, replacements, _workspace_id), do: {tab, replacements}

  @spec tab_matches_file_ref?(Tab.t(), FileRef.t()) :: boolean()
  defp tab_matches_file_ref?(%Tab{} = tab, %FileRef{} = file_ref) do
    case tab_file_ref(tab) do
      %FileRef{} = tab_ref -> FileRef.equal?(tab_ref, file_ref)
      nil -> false
    end
  end

  @spec tab_file_ref(Tab.t()) :: FileRef.t() | nil
  defp tab_file_ref(%Tab{file_ref: %FileRef{} = file_ref}), do: file_ref
  defp tab_file_ref(%Tab{}), do: nil

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
    ws = Workspace.new_agent(tb.next_workspace_id, label, session, project_root(tb))

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
    remove_workspace_in_memory(tb, workspace_id)
  end

  @spec remove_workspace_in_memory(t(), non_neg_integer()) :: t()
  defp remove_workspace_in_memory(%__MODULE__{} = tb, workspace_id) do
    closing_workspace = get_workspace(tb, workspace_id)
    workspaces = Enum.reject(tb.workspaces, &(&1.id == workspace_id))

    tabs =
      Enum.map(tb.tabs, fn tab ->
        if tab.group_id == workspace_id do
          tab
          |> Tab.set_group(0)
          |> scrub_migrated_workspace_tab(closing_workspace)
        else
          tab
        end
      end)

    %{tb | workspaces: workspaces, tabs: tabs}
  end

  @spec scrub_migrated_workspace_tab(Tab.t(), Workspace.t() | nil) :: Tab.t()
  defp scrub_migrated_workspace_tab(%Tab{} = tab, %Workspace{kind: :agent}) do
    Tab.clear_agent_projection(tab)
  end

  defp scrub_migrated_workspace_tab(%Tab{} = tab, _workspace), do: tab

  @doc "Moves a tab to a different workspace."
  @spec move_tab_to_workspace(t(), Tab.id(), non_neg_integer()) :: t()
  def move_tab_to_workspace(%__MODULE__{} = tb, tab_id, workspace_id) do
    replace_matching_tab(tb, tab_id, &Tab.set_group(&1, workspace_id))
  end

  @doc """
  Switches to the given workspace by activating its first visible tab.

  Returns unchanged if the workspace doesn't exist or has no visible tabs.
  """
  @spec switch_to_workspace(t(), non_neg_integer()) :: t()
  def switch_to_workspace(%__MODULE__{} = tb, workspace_id) do
    if Enum.any?(tb.workspaces, &(&1.id == workspace_id)) do
      switch_to_first_visible_tab_in(tb, workspace_id)
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

    switch_to_first_visible_tab_in(tb, next.id)
  end

  defp switch_to_cycled_agent_workspace(tb, workspaces, :prev) do
    current_id = active_workspace_id(tb)
    idx = Enum.find_index(workspaces, &(&1.id == current_id)) || 0
    len = length(workspaces)
    prev_idx = if idx == 0, do: len - 1, else: idx - 1
    prev = Enum.at(workspaces, prev_idx)
    switch_to_first_visible_tab_in(tb, prev.id)
  end

  # Switches active_id to the first visible tab in the given workspace.
  # Returns unchanged if the workspace has no visible tabs.
  @spec switch_to_first_visible_tab_in(t(), non_neg_integer()) :: t()
  defp switch_to_first_visible_tab_in(tb, workspace_id) do
    case visible_workspace_tabs(tb, workspace_id) do
      [first | _] -> %{tb | active_id: first.id}
      [] -> tb
    end
  end

  @doc "Returns the workspace matching the given session pid, or nil."
  @spec find_workspace_by_session(t(), pid()) :: Workspace.t() | nil
  def find_workspace_by_session(%__MODULE__{workspaces: workspaces}, session_pid)
      when is_pid(session_pid) do
    Enum.find(workspaces, fn
      %Workspace{payload: %WorkspaceAgent{session: ^session_pid}} -> true
      _ -> false
    end)
  end

  @spec replace_matching_workspace(t(), non_neg_integer(), (Workspace.t() -> Workspace.t())) ::
          t()
  defp replace_matching_workspace(
         %__MODULE__{workspaces: workspaces} = tab_bar,
         workspace_id,
         transition
       ) do
    workspaces =
      Enum.map(workspaces, fn
        %Workspace{id: ^workspace_id} = workspace ->
          transition.(workspace)

        workspace ->
          workspace
      end)

    %{tab_bar | workspaces: workspaces}
  end

  @doc "Accepts a concrete workspace only at its existing stable identity."
  @spec accept_workspace(t(), Workspace.t()) :: t()
  def accept_workspace(%__MODULE__{} = tab_bar, %Workspace{id: workspace_id} = accepted) do
    replace_matching_workspace(tab_bar, workspace_id, fn _current -> accepted end)
  end

  @doc "Renames the identified workspace."
  @spec rename_workspace(t(), non_neg_integer(), String.t()) :: t()
  def rename_workspace(tab_bar, workspace_id, name) do
    replace_matching_workspace(tab_bar, workspace_id, &Workspace.rename(&1, name))
  end

  @doc "Sets the icon of the identified workspace."
  @spec set_workspace_icon(t(), non_neg_integer(), String.t()) :: t()
  def set_workspace_icon(tab_bar, workspace_id, icon) do
    replace_matching_workspace(tab_bar, workspace_id, &Workspace.set_icon(&1, icon))
  end

  @doc "Records agent status on the identified workspace."
  @spec set_workspace_agent_status(t(), non_neg_integer(), Tab.agent_status()) :: t()
  def set_workspace_agent_status(tab_bar, workspace_id, status) do
    replace_matching_workspace(tab_bar, workspace_id, &Workspace.set_agent_status(&1, status))
  end

  @doc "Binds or clears the identified workspace session."
  @spec set_workspace_session(t(), non_neg_integer(), pid() | nil) :: t()
  def set_workspace_session(tab_bar, workspace_id, session) do
    replace_matching_workspace(tab_bar, workspace_id, &Workspace.set_session(&1, session))
  end

  @doc "Clears session state from the identified workspace."
  @spec clear_workspace_session(t(), non_neg_integer()) :: t()
  def clear_workspace_session(tab_bar, workspace_id) do
    replace_matching_workspace(tab_bar, workspace_id, &Workspace.clear_session/1)
  end

  @doc "Records the agent UI projection on the identified workspace."
  @spec set_workspace_agent_ui(t(), non_neg_integer(), MingaEditor.Agent.UIState.t()) :: t()
  def set_workspace_agent_ui(tab_bar, workspace_id, agent_ui) do
    replace_matching_workspace(tab_bar, workspace_id, &Workspace.set_agent_ui(&1, agent_ui))
  end

  @doc "Records project-view state on the identified workspace."
  @spec set_workspace_project_view(t(), non_neg_integer(), term()) :: t()
  def set_workspace_project_view(tab_bar, workspace_id, project_view) do
    replace_matching_workspace(
      tab_bar,
      workspace_id,
      &Workspace.set_project_view(&1, project_view)
    )
  end

  @doc "Adds a file identity to the identified workspace."
  @spec add_workspace_file(t(), non_neg_integer(), FileRef.t()) :: t()
  def add_workspace_file(tab_bar, workspace_id, %FileRef{} = file_ref) do
    replace_matching_workspace(tab_bar, workspace_id, &Workspace.add_file(&1, file_ref))
  end

  @doc "Removes a file identity from the identified workspace."
  @spec remove_workspace_file(t(), non_neg_integer(), FileRef.t()) :: t()
  def remove_workspace_file(tab_bar, workspace_id, %FileRef{} = file_ref) do
    replace_matching_workspace(tab_bar, workspace_id, &Workspace.remove_file(&1, file_ref))
  end

  @doc "Records pending durable catch-up events on the identified workspace."
  @spec set_workspace_pending_catchup_events(t(), non_neg_integer(), [term()]) :: t()
  def set_workspace_pending_catchup_events(tab_bar, workspace_id, events) when is_list(events) do
    replace_matching_workspace(
      tab_bar,
      workspace_id,
      &Workspace.set_pending_catchup_events(&1, events)
    )
  end

  @doc "Records remote connection status on the identified workspace."
  @spec set_workspace_remote_connection_status(t(), non_neg_integer(), Tab.connection_status()) ::
          t()
  def set_workspace_remote_connection_status(tab_bar, workspace_id, status) do
    replace_matching_workspace(
      tab_bar,
      workspace_id,
      &Workspace.set_remote_connection_status(&1, status)
    )
  end

  @doc "Retargets one file identity in the identified workspace."
  @spec retarget_workspace_file(t(), non_neg_integer(), FileRef.t() | nil, FileRef.t()) :: t()
  def retarget_workspace_file(tab_bar, workspace_id, old_file_ref, %FileRef{} = file_ref) do
    replace_matching_workspace(tab_bar, workspace_id, fn workspace ->
      Workspace.retarget_file(workspace, old_file_ref, file_ref)
    end)
  end

  @doc "Records review state on the identified workspace."
  @spec set_workspace_review(t(), non_neg_integer(), MingaEditor.State.WorkspaceReview.t()) :: t()
  def set_workspace_review(tab_bar, workspace_id, review) do
    replace_matching_workspace(tab_bar, workspace_id, &Workspace.set_review(&1, review))
  end

  @doc "Replaces restored workspaces and recalculates the next workspace id."
  @spec restore_workspaces(t(), [Workspace.t()], String.t() | nil) :: t()
  def restore_workspaces(%__MODULE__{} = tb, [], _project_root), do: tb

  def restore_workspaces(%__MODULE__{} = tb, workspaces, project_root) when is_list(workspaces) do
    workspaces = ensure_manual_workspace(workspaces, project_root)
    {tabs, next_id} = ensure_restored_workspace_tabs(tb.tabs, tb.next_id, workspaces)

    %{
      tb
      | tabs: tabs,
        next_id: next_id,
        workspaces: workspaces,
        next_workspace_id: next_restored_workspace_id(workspaces)
    }
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

  @spec project_root(t()) :: String.t() | nil
  defp project_root(%__MODULE__{workspaces: workspaces}) do
    case Enum.find(workspaces, &(&1.id == 0)) do
      %Workspace{project_root: root} -> root
      nil -> nil
    end
  end

  @spec ensure_manual_workspace([Workspace.t()], String.t() | nil) :: [Workspace.t()]
  defp ensure_manual_workspace(workspaces, project_root) do
    case Enum.find(workspaces, &(&1.id == 0)) do
      %Workspace{} -> workspaces
      nil -> [Workspace.new_manual(project_root) | workspaces]
    end
  end

  @spec ensure_restored_workspace_tabs([Tab.t()], Tab.id(), [Workspace.t()]) ::
          {[Tab.t()], Tab.id()}
  defp ensure_restored_workspace_tabs(tabs, next_id, workspaces) do
    Enum.reduce(workspaces, {tabs, next_id}, &ensure_restored_workspace_tab/2)
  end

  @spec ensure_restored_workspace_tab(Workspace.t(), {[Tab.t()], Tab.id()}) ::
          {[Tab.t()], Tab.id()}
  defp ensure_restored_workspace_tab(
         %Workspace{kind: :agent, id: workspace_id, label: label},
         {tabs, next_id}
       ) do
    if Enum.any?(tabs, &(&1.group_id == workspace_id)) do
      {tabs, next_id}
    else
      restored_tab =
        next_id
        |> Tab.new_agent(label)
        |> Tab.set_group(workspace_id)

      {Enum.concat(tabs, [restored_tab]), next_id + 1}
    end
  end

  defp ensure_restored_workspace_tab(%Workspace{}, acc), do: acc

  @spec next_restored_workspace_id([Workspace.t()]) :: pos_integer()
  defp next_restored_workspace_id(workspaces) do
    workspaces
    |> Enum.map(& &1.id)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
    |> max(1)
  end

  @spec agent_workspaces(t()) :: [Workspace.t()]
  defp agent_workspaces(%__MODULE__{workspaces: workspaces}) do
    Enum.filter(workspaces, &(&1.kind == :agent))
  end
end
