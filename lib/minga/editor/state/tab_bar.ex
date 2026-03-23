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

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.Workspace

  @typedoc "Tab bar state."
  @type t :: %__MODULE__{
          tabs: [Tab.t()],
          active_id: Tab.id(),
          next_id: Tab.id(),
          workspaces: [Workspace.t()],
          active_workspace_id: non_neg_integer(),
          next_workspace_id: pos_integer()
        }

  @enforce_keys [:tabs, :active_id, :next_id]
  defstruct tabs: [],
            active_id: 1,
            next_id: 2,
            workspaces: [Workspace.manual()],
            active_workspace_id: 0,
            next_workspace_id: 1

  @doc "Creates a tab bar with a single initial tab."
  @spec new(Tab.t()) :: t()
  def new(%Tab{} = tab) do
    %__MODULE__{tabs: [tab], active_id: tab.id, next_id: tab.id + 1}
  end

  @doc "Returns the active tab."
  @spec active(t()) :: Tab.t()
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

  @doc "Returns the active workspace."
  @spec active_workspace(t()) :: Workspace.t() | nil
  def active_workspace(%__MODULE__{} = tb) do
    get_workspace(tb, tb.active_workspace_id)
  end

  @doc """
  Adds an agent workspace and returns `{updated_tab_bar, workspace}`.

  The workspace is inserted after the manual workspace. The `session` pid
  is stored so we can track which agent owns the workspace.
  """
  @spec add_agent_workspace(t(), String.t(), pid() | nil) :: {t(), Workspace.t()}
  def add_agent_workspace(%__MODULE__{} = tb, label, session \\ nil) do
    ws = Workspace.new_agent(tb.next_workspace_id, label, session)

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    workspaces = tb.workspaces ++ [ws]

    {%{tb | workspaces: workspaces, next_workspace_id: tb.next_workspace_id + 1}, ws}
  end

  @doc """
  Removes a workspace and migrates its tabs to the manual workspace (id 0).

  The manual workspace (id 0) cannot be removed.
  """
  @spec remove_workspace(t(), non_neg_integer()) :: t()
  def remove_workspace(%__MODULE__{} = tb, 0), do: tb

  def remove_workspace(%__MODULE__{} = tb, workspace_id) do
    workspaces = Enum.reject(tb.workspaces, &(&1.id == workspace_id))

    tabs =
      Enum.map(tb.tabs, fn tab ->
        if tab.group_id == workspace_id, do: %{tab | group_id: 0}, else: tab
      end)

    active_ws =
      if tb.active_workspace_id == workspace_id, do: 0, else: tb.active_workspace_id

    %{tb | workspaces: workspaces, tabs: tabs, active_workspace_id: active_ws}
  end

  @doc "Moves a tab to a different workspace."
  @spec move_tab_to_workspace(t(), Tab.id(), non_neg_integer()) :: t()
  def move_tab_to_workspace(%__MODULE__{} = tb, tab_id, workspace_id) do
    update_tab(tb, tab_id, &Tab.set_group(&1, workspace_id))
  end

  @doc "Switches to the given workspace."
  @spec switch_workspace(t(), non_neg_integer()) :: t()
  def switch_workspace(%__MODULE__{} = tb, workspace_id) do
    if Enum.any?(tb.workspaces, &(&1.id == workspace_id)) do
      %{tb | active_workspace_id: workspace_id}
    else
      tb
    end
  end

  @doc "Switches to the next workspace, wrapping around."
  @spec next_workspace(t()) :: t()
  def next_workspace(%__MODULE__{workspaces: [_single]} = tb), do: tb

  def next_workspace(%__MODULE__{workspaces: workspaces} = tb) do
    idx =
      Enum.find_index(workspaces, &(&1.id == tb.active_workspace_id)) || 0

    next_idx = rem(idx + 1, length(workspaces))
    next_ws = Enum.at(workspaces, next_idx)
    %{tb | active_workspace_id: next_ws.id}
  end

  @doc "Switches to the previous workspace, wrapping around."
  @spec prev_workspace(t()) :: t()
  def prev_workspace(%__MODULE__{workspaces: [_single]} = tb), do: tb

  def prev_workspace(%__MODULE__{workspaces: workspaces} = tb) do
    idx =
      Enum.find_index(workspaces, &(&1.id == tb.active_workspace_id)) || 0

    len = length(workspaces)
    prev_idx = if idx == 0, do: len - 1, else: idx - 1
    prev_ws = Enum.at(workspaces, prev_idx)
    %{tb | active_workspace_id: prev_ws.id}
  end

  @doc "Switches to the next agent workspace, skipping manual."
  @spec next_agent_workspace(t()) :: t()
  def next_agent_workspace(%__MODULE__{workspaces: workspaces} = tb) do
    agent_ws = Enum.filter(workspaces, &Workspace.agent?/1)

    case agent_ws do
      [] ->
        tb

      [only] ->
        %{tb | active_workspace_id: only.id}

      _ ->
        current_idx =
          Enum.find_index(agent_ws, &(&1.id == tb.active_workspace_id))

        next_ws =
          case current_idx do
            nil -> hd(agent_ws)
            idx -> Enum.at(agent_ws, rem(idx + 1, length(agent_ws)))
          end

        %{tb | active_workspace_id: next_ws.id}
    end
  end

  @doc "Returns the workspace matching the given session pid, or nil."
  @spec find_workspace_by_session(t(), pid()) :: Workspace.t() | nil
  def find_workspace_by_session(%__MODULE__{workspaces: workspaces}, session_pid)
      when is_pid(session_pid) do
    Enum.find(workspaces, fn
      %Workspace{kind: :agent, session: ^session_pid} -> true
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
  def has_agent_workspaces?(%__MODULE__{workspaces: workspaces}) do
    Enum.any?(workspaces, &Workspace.agent?/1)
  end

  @doc "Returns the progressive disclosure tier (0-3) based on workspace count."
  @spec disclosure_tier(t()) :: 0 | 1 | 2 | 3
  def disclosure_tier(%__MODULE__{} = tb) do
    agent_count = Enum.count(tb.workspaces, &Workspace.agent?/1)

    case agent_count do
      0 -> 0
      1 -> 1
      n when n <= 4 -> 2
      _ -> 3
    end
  end
end
