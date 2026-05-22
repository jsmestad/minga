defmodule MingaEditor.State.AgentAccess do
  @moduledoc """
  Direct accessors for agent state on EditorState.

  Agent lifecycle data is workspace-owned for the Traditional shell. The active agent workspace stores its session pid and `MingaEditor.Agent.UIState`; `state.workspace.agent_ui` is only a live mirror for renderers that still read the current workspace struct directly.

  The Board shell still owns session pids on cards until it moves to the same workspace model.
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.Session.State, as: WorkspaceState

  # ── Readers ────────────────────────────────────────────────────────────────

  @doc "Returns the agent session lifecycle state."
  @spec agent(EditorState.t() | map()) :: AgentState.t()
  def agent(%EditorState{shell_state: %{agent: a}}), do: a
  def agent(%{shell_state: %{agent: a}}), do: a
  def agent(%{agent: a}), do: a
  def agent(_), do: %AgentState{}

  @doc "Returns the full agent UI state (wrapping Panel and View)."
  @spec agent_ui(EditorState.t() | map()) :: UIState.t()
  def agent_ui(%EditorState{} = state),
    do: active_workspace_agent_ui(state) || state.workspace.agent_ui

  def agent_ui(%{shell_state: %{tab_bar: %TabBar{}}, workspace: %{agent_ui: agent_ui}} = state),
    do: active_workspace_agent_ui(state) || agent_ui || UIState.new()

  def agent_ui(%{workspace: %{agent_ui: a}}), do: a || UIState.new()
  def agent_ui(%{agent_ui: a}), do: a || UIState.new()
  def agent_ui(_), do: UIState.new()

  @doc "Returns the agent panel state (prompt editing and chat display)."
  @spec panel(EditorState.t() | map()) :: Panel.t()
  def panel(state), do: agent_ui(state).panel

  @doc "Returns the agent view state (layout, search, preview, toasts)."
  @spec view(EditorState.t() | map()) :: View.t()
  def view(state), do: agent_ui(state).view

  @doc """
  Returns the agent session pid for the user's current view, or `nil`.

  Traditional reads the active workspace. Board reads through the shell behaviour until Board moves onto the same workspace model.
  """
  @spec session(EditorState.t() | map()) :: pid() | nil
  def session(%EditorState{shell: MingaEditor.Shell.Traditional} = state) do
    active_workspace_session(state)
  end

  def session(%{shell: MingaEditor.Shell.Traditional} = state) do
    active_workspace_session(state)
  end

  def session(%EditorState{shell: shell, shell_state: shell_state})
      when is_atom(shell) and not is_nil(shell) do
    shell.active_session(shell_state)
  end

  def session(%{shell: shell, shell_state: shell_state})
      when is_atom(shell) and not is_nil(shell) do
    shell.active_session(shell_state)
  end

  def session(_), do: nil

  @doc "Returns true if the agent panel input is focused."
  @spec input_focused?(EditorState.t() | map()) :: boolean()
  def input_focused?(state), do: panel(state).input_focused

  @doc "Returns the agent UI focus."
  @spec focus(EditorState.t() | map()) :: atom()
  def focus(state), do: view(state).focus

  # ── Writers ────────────────────────────────────────────────────────────────

  @doc "Updates agent session lifecycle state via a transform function."
  @spec update_agent(EditorState.t() | map(), (AgentState.t() -> AgentState.t())) ::
          EditorState.t() | map()
  def update_agent(%EditorState{shell_state: %{agent: a} = ss} = state, fun) do
    %{state | shell_state: %{ss | agent: fun.(a)}}
  end

  def update_agent(%{shell_state: %{agent: a} = ss} = state, fun) do
    %{state | shell_state: %{ss | agent: fun.(a)}}
  end

  def update_agent(%{agent: a} = state, fun) do
    %{state | agent: fun.(a)}
  end

  @doc deprecated: "Use update_panel/2 or update_view/2 for targeted sub-struct updates"
  @doc "Updates the full agent UI state. Prefer update_panel/2 or update_view/2."
  @spec update_agent_ui(EditorState.t() | map(), (UIState.t() -> UIState.t())) ::
          EditorState.t() | map()
  def update_agent_ui(%EditorState{} = state, fun) do
    update_workspace_agent_ui(state, fun)
  end

  def update_agent_ui(%{shell_state: %{tab_bar: %TabBar{}}} = state, fun) do
    update_workspace_agent_ui(state, fun)
  end

  def update_agent_ui(%{workspace: %{agent_ui: a} = ws} = state, fun) do
    %{state | workspace: %{ws | agent_ui: fun.(a || UIState.new())}}
  end

  def update_agent_ui(%{agent_ui: a} = state, fun) do
    %{state | agent_ui: fun.(a)}
  end

  @doc "Updates just the panel sub-struct via a transform function."
  @spec update_panel(EditorState.t() | map(), (Panel.t() -> Panel.t())) ::
          EditorState.t() | map()
  def update_panel(state, fun) do
    update_agent_ui(state, fn
      %UIState{panel: %Panel{} = panel} = ui -> %{ui | panel: fun.(panel)}
      _ -> %{UIState.new() | panel: fun.(Panel.new())}
    end)
  end

  @doc "Updates just the view sub-struct via a transform function."
  @spec update_view(EditorState.t() | map(), (View.t() -> View.t())) ::
          EditorState.t() | map()
  def update_view(state, fun) do
    update_agent_ui(state, fn
      %UIState{view: %View{} = view} = ui -> %{ui | view: fun.(view)}
      _ -> %{UIState.new() | view: fun.(View.new())}
    end)
  end

  @spec active_workspace_agent_ui(EditorState.t() | map()) :: UIState.t() | nil
  defp active_workspace_agent_ui(%{shell_state: %{tab_bar: %TabBar{} = tab_bar}}) do
    case TabBar.active_workspace(tab_bar) do
      %Workspace{agent_ui: %UIState{} = agent_ui} -> agent_ui
      _ -> nil
    end
  end

  defp active_workspace_agent_ui(_state), do: nil

  @spec active_workspace_session(EditorState.t() | map()) :: pid() | nil
  defp active_workspace_session(%{shell_state: %{tab_bar: %TabBar{} = tab_bar}}) do
    case TabBar.active_workspace(tab_bar) do
      %Workspace{session: session} when is_pid(session) -> session
      _ -> nil
    end
  end

  defp active_workspace_session(_state), do: nil

  @spec update_workspace_agent_ui(EditorState.t() | map(), (UIState.t() -> UIState.t())) ::
          EditorState.t() | map()
  defp update_workspace_agent_ui(
         %{shell_state: %{tab_bar: %TabBar{} = tab_bar}, workspace: workspace} = state,
         fun
       ) do
    current_ui =
      active_workspace_agent_ui(state) || Map.get(workspace, :agent_ui) || UIState.new()

    next_ui = fun.(current_ui)

    tab_bar =
      case TabBar.active_workspace(tab_bar) do
        %Workspace{kind: :agent, id: workspace_id} ->
          TabBar.update_workspace(tab_bar, workspace_id, &Workspace.set_agent_ui(&1, next_ui))

        %Workspace{session: session, id: workspace_id} when is_pid(session) ->
          TabBar.update_workspace(tab_bar, workspace_id, &Workspace.set_agent_ui(&1, next_ui))

        _workspace ->
          tab_bar
      end

    state
    |> set_tab_bar(tab_bar)
    |> set_workspace(set_live_agent_ui(workspace, next_ui))
  end

  defp update_workspace_agent_ui(%{workspace: %{agent_ui: agent_ui} = workspace} = state, fun) do
    next_ui = fun.(agent_ui || UIState.new())
    %{state | workspace: set_live_agent_ui(workspace, next_ui)}
  end

  @spec set_tab_bar(EditorState.t() | map(), TabBar.t()) :: EditorState.t() | map()
  defp set_tab_bar(%EditorState{} = state, %TabBar{} = tab_bar) do
    EditorState.set_tab_bar(state, tab_bar)
  end

  defp set_tab_bar(%{shell_state: shell_state} = state, %TabBar{} = tab_bar) do
    %{state | shell_state: ShellState.set_tab_bar(shell_state, tab_bar)}
  end

  @spec set_workspace(EditorState.t() | map(), WorkspaceState.t() | map()) ::
          EditorState.t() | map()
  defp set_workspace(%EditorState{} = state, %WorkspaceState{} = workspace) do
    EditorState.set_workspace(state, workspace)
  end

  defp set_workspace(%{workspace: _workspace} = state, workspace) do
    %{state | workspace: workspace}
  end

  @spec set_live_agent_ui(WorkspaceState.t() | map(), UIState.t()) :: WorkspaceState.t() | map()
  defp set_live_agent_ui(%WorkspaceState{} = workspace, %UIState{} = agent_ui) do
    WorkspaceState.set_agent_ui(workspace, agent_ui)
  end

  defp set_live_agent_ui(workspace, %UIState{} = agent_ui) when is_map(workspace) do
    Map.put(workspace, :agent_ui, agent_ui)
  end
end
