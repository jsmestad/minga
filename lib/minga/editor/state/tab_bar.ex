defmodule Minga.Editor.State.TabBar do
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

  alias Minga.Editor.State.AgentGroup
  alias Minga.Editor.State.Tab

  @typedoc "Tab bar state."
  @type t :: %__MODULE__{
          tabs: [Tab.t()],
          active_id: Tab.id(),
          next_id: Tab.id(),
          agent_groups: [AgentGroup.t()],
          next_group_id: pos_integer()
        }

  @enforce_keys [:tabs, :active_id, :next_id]
  defstruct tabs: [],
            active_id: 1,
            next_id: 2,
            agent_groups: [],
            next_group_id: 1

  @doc "Creates a tab bar with a single initial tab."
  @spec new(Tab.t()) :: t()
  def new(%Tab{} = tab) do
    %__MODULE__{tabs: [tab], active_id: tab.id, next_id: tab.id + 1}
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

  @doc "Switches to the next tab, wrapping around."
  @spec next(t()) :: t()
  def next(%__MODULE__{tabs: [_single]} = tb), do: tb

  def next(%__MODULE__{tabs: tabs} = tb) do
    idx = active_index(tb)
    next_idx = rem(idx + 1, length(tabs))
    next_tab = Enum.at(tabs, next_idx)
    %{tb | active_id: next_tab.id}
  end

  @doc "Switches to the previous tab, wrapping around."
  @spec prev(t()) :: t()
  def prev(%__MODULE__{tabs: [_single]} = tb), do: tb

  def prev(%__MODULE__{tabs: tabs} = tb) do
    idx = active_index(tb)
    len = length(tabs)
    prev_idx = if idx == 0, do: len - 1, else: idx - 1
    prev_tab = Enum.at(tabs, prev_idx)
    %{tb | active_id: prev_tab.id}
  end

  @doc "Updates the context of the tab with the given id."
  @spec update_context(t(), Tab.id(), Tab.context()) :: t()
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

  @doc "Sets the attention flag on the tab matching the given session pid."
  @spec set_attention_by_session(t(), pid(), boolean()) :: t()
  def set_attention_by_session(%__MODULE__{} = tb, session_pid, value)
      when is_pid(session_pid) and is_boolean(value) do
    case find_by_session(tb, session_pid) do
      %Tab{id: id} -> update_tab(tb, id, &Tab.set_attention(&1, value))
      nil -> tb
    end
  end

  # ── AgentGroup management ───────────────────────────────────────────────────

  @doc "Returns all tabs belonging to the given agent group."
  @spec tabs_in_group(t(), non_neg_integer()) :: [Tab.t()]
  def tabs_in_group(%__MODULE__{tabs: tabs}, group_id) do
    Enum.filter(tabs, &(&1.group_id == group_id))
  end

  @doc "Returns the agent group with the given id, or nil."
  @spec get_group(t(), non_neg_integer()) :: AgentGroup.t() | nil
  def get_group(%__MODULE__{agent_groups: agent_groups}, id) do
    Enum.find(agent_groups, &(&1.id == id))
  end

  @doc """
  Returns the active agent group.

  Derived from the active tab's group_id, not stored separately.
  The active agent group is always the agent group of the tab you're looking at.
  """
  @spec active_group(t()) :: AgentGroup.t() | nil
  def active_group(%__MODULE__{} = tb) do
    case active(tb) do
      %Tab{group_id: gid} -> get_group(tb, gid)
      nil -> get_group(tb, 0)
    end
  end

  @doc "Returns the active agent group id, derived from the active tab."
  @spec active_group_id(t()) :: non_neg_integer()
  def active_group_id(%__MODULE__{} = tb) do
    case active(tb) do
      %Tab{group_id: gid} -> gid
      nil -> 0
    end
  end

  @doc """
  Adds an agent agent group and returns `{updated_tab_bar, agent group}`.

  The agent group is appended to the agent groups list. The `session` pid
  is stored so we can track which agent owns the agent group.
  """
  @spec add_agent_group(t(), String.t(), pid() | nil) :: {t(), AgentGroup.t()}
  def add_agent_group(%__MODULE__{} = tb, label, session \\ nil) do
    ws = AgentGroup.new(tb.next_group_id, label, session)

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    agent_groups = tb.agent_groups ++ [ws]

    {%{tb | agent_groups: agent_groups, next_group_id: tb.next_group_id + 1}, ws}
  end

  @doc """
  Removes a agent group and migrates its tabs to ungrouped (group_id 0).

  Cannot remove group_id 0 (ungrouped tabs).
  """
  @spec remove_group(t(), non_neg_integer()) :: t()
  def remove_group(%__MODULE__{} = tb, 0), do: tb

  def remove_group(%__MODULE__{} = tb, group_id) do
    agent_groups = Enum.reject(tb.agent_groups, &(&1.id == group_id))

    tabs =
      Enum.map(tb.tabs, fn tab ->
        if tab.group_id == group_id, do: %{tab | group_id: 0}, else: tab
      end)

    %{tb | agent_groups: agent_groups, tabs: tabs}
  end

  @doc "Moves a tab to a different agent group."
  @spec move_tab_to_group(t(), Tab.id(), non_neg_integer()) :: t()
  def move_tab_to_group(%__MODULE__{} = tb, tab_id, group_id) do
    update_tab(tb, tab_id, &Tab.set_group(&1, group_id))
  end

  @doc """
  Switches to the given agent group by activating its first tab.

  Returns unchanged if the agent group doesn't exist or has no tabs.
  """
  @spec switch_to_group(t(), non_neg_integer()) :: t()
  def switch_to_group(%__MODULE__{} = tb, group_id) do
    if Enum.any?(tb.agent_groups, &(&1.id == group_id)) do
      switch_to_first_tab_in(tb, group_id)
    else
      tb
    end
  end

  @doc "Switches to the next agent group, wrapping around. No-op if no groups."
  @spec next_agent_group(t()) :: t()
  def next_agent_group(%__MODULE__{agent_groups: []} = tb), do: tb

  def next_agent_group(%__MODULE__{agent_groups: groups} = tb) do
    current_id = active_group_id(tb)
    current_idx = Enum.find_index(groups, &(&1.id == current_id))

    next =
      case current_idx do
        nil -> hd(groups)
        idx -> Enum.at(groups, rem(idx + 1, length(groups)))
      end

    switch_to_first_tab_in(tb, next.id)
  end

  @doc "Switches to the previous agent group, wrapping around. No-op if no groups."
  @spec prev_agent_group(t()) :: t()
  def prev_agent_group(%__MODULE__{agent_groups: []} = tb), do: tb

  def prev_agent_group(%__MODULE__{agent_groups: groups} = tb) do
    current_id = active_group_id(tb)
    idx = Enum.find_index(groups, &(&1.id == current_id)) || 0
    len = length(groups)
    prev_idx = if idx == 0, do: len - 1, else: idx - 1
    prev = Enum.at(groups, prev_idx)
    switch_to_first_tab_in(tb, prev.id)
  end

  # Switches active_id to the first tab in the given agent group.
  # Returns unchanged if the agent group has no tabs.
  @spec switch_to_first_tab_in(t(), non_neg_integer()) :: t()
  defp switch_to_first_tab_in(tb, group_id) do
    case tabs_in_group(tb, group_id) do
      [first | _] -> %{tb | active_id: first.id}
      [] -> tb
    end
  end

  @doc "Returns the agent group matching the given session pid, or nil."
  @spec find_group_by_session(t(), pid()) :: AgentGroup.t() | nil
  def find_group_by_session(%__MODULE__{agent_groups: agent_groups}, session_pid)
      when is_pid(session_pid) do
    Enum.find(agent_groups, fn
      %AgentGroup{session: ^session_pid} -> true
      _ -> false
    end)
  end

  @doc """
  Updates a agent group by applying `fun` to it.

  Returns unchanged tab bar if no agent group matches.
  """
  @spec update_group(t(), non_neg_integer(), (AgentGroup.t() -> AgentGroup.t())) :: t()
  def update_group(%__MODULE__{agent_groups: agent_groups} = tb, id, fun)
      when is_function(fun, 1) do
    new_agent_groups =
      Enum.map(agent_groups, fn
        %AgentGroup{id: ^id} = ws -> fun.(ws)
        ws -> ws
      end)

    %{tb | agent_groups: new_agent_groups}
  end

  @doc "Returns true if any agent agent_groups exist."
  @spec has_agent_groups?(t()) :: boolean()
  def has_agent_groups?(%__MODULE__{agent_groups: groups}) do
    groups != []
  end

  @doc "Returns the progressive disclosure tier (0-3) based on agent group count."
  @spec disclosure_tier(t()) :: 0 | 1 | 2 | 3
  def disclosure_tier(%__MODULE__{} = tb) do
    agent_count = length(tb.agent_groups)

    case agent_count do
      0 -> 0
      1 -> 1
      n when n <= 4 -> 2
      _ -> 3
    end
  end
end
