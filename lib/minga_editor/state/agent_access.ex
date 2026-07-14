defmodule MingaEditor.State.AgentAccess do
  @moduledoc """
  Direct accessors for agent state on EditorState.

  Agent lifecycle data is workspace-owned for the Traditional shell. The active agent workspace stores its session pid and `MingaEditor.Agent.UIState`; `state.workspace.agent_ui` is only a live mirror for renderers that still read the current workspace struct directly.

  Extension shells may own session pids on shell-specific surfaces until they move to the same workspace model.
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Shell.Traditional.AgentSurfaces
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.State.InlineEdit
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Workflow
  alias MingaEditor.Session.State, as: WorkspaceState

  # ── Readers ────────────────────────────────────────────────────────────────

  @doc "Returns the agent session lifecycle state."
  @spec agent(EditorState.t() | map()) :: AgentState.t()
  def agent(%EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}}),
    do: TraditionalState.agent(shell_state)

  def agent(%{shell_state: %TraditionalState{} = shell_state}),
    do: TraditionalState.agent(shell_state)

  def agent(%{agent_surfaces: %AgentSurfaces{} = surfaces}),
    do: AgentSurfaces.presentation(surfaces)

  def agent(_), do: %AgentState{}

  @doc "Returns the full agent UI state (wrapping Panel and View)."
  @spec agent_ui(EditorState.t() | map()) :: UIState.t()
  def agent_ui(%EditorState{} = state),
    do: active_workspace_agent_ui(state) || state.workspace.agent_ui

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

  Traditional reads the active workspace. Extension shells read through shell behaviours until they move onto the same workspace model.
  """
  @spec session(EditorState.t() | map()) :: pid() | nil
  def session(%EditorState{} = state) do
    state = Workflow.ensure_available(state)

    case state.shell_runtime do
      %Runtime{entry: %Entry{id: :traditional}} -> active_workspace_session(state)
      %Runtime{} = runtime -> Runtime.active_session(runtime)
    end
  end

  def session(_), do: nil

  @doc "Returns true if the agent panel input is focused."
  @spec input_focused?(EditorState.t() | map()) :: boolean()
  def input_focused?(state), do: panel(state).input_focused

  @doc "Returns the agent UI focus."
  @spec focus(EditorState.t() | map()) :: atom()
  def focus(state), do: state |> view() |> View.focus()

  # ── Writers ────────────────────────────────────────────────────────────────

  @doc "Updates agent session lifecycle state via the Traditional surface owner."
  @spec update_agent(EditorState.t(), (AgentState.t() -> AgentState.t())) :: EditorState.t()
  def update_agent(%EditorState{} = state, fun) do
    runtime =
      Runtime.update_traditional_state(state.shell_runtime, fn shell_state ->
        TraditionalState.replace_agent(shell_state, fun.(TraditionalState.agent(shell_state)))
      end)

    EditorState.apply_shell_runtime_transition(state, runtime)
  end

  @doc "Returns the Traditional inline ask store."
  @spec inline_asks(EditorState.t() | map()) :: InlineAsk.store()
  def inline_asks(%EditorState{
        shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}
      }),
      do: TraditionalState.inline_asks(shell_state)

  def inline_asks(%{shell_state: %TraditionalState{} = shell_state}),
    do: TraditionalState.inline_asks(shell_state)

  def inline_asks(%{agent_surfaces: %AgentSurfaces{} = surfaces}),
    do: AgentSurfaces.asks(surfaces)

  def inline_asks(_state), do: %{}

  @doc "Returns the Traditional inline edit store."
  @spec inline_edits(EditorState.t() | map()) :: InlineEdit.store()
  def inline_edits(%EditorState{
        shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}
      }),
      do: TraditionalState.inline_edits(shell_state)

  def inline_edits(%{shell_state: %TraditionalState{} = shell_state}),
    do: TraditionalState.inline_edits(shell_state)

  def inline_edits(%{agent_surfaces: %AgentSurfaces{} = surfaces}),
    do: AgentSurfaces.edits(surfaces)

  def inline_edits(_state), do: %{}

  @doc "Activates or replaces one inline ask through its surface owner."
  @spec replace_inline_ask(EditorState.t(), InlineAsk.t()) :: EditorState.t()
  def replace_inline_ask(%EditorState{} = state, %InlineAsk{} = ask),
    do: update_traditional(state, &TraditionalState.replace_inline_ask(&1, ask))

  @doc "Cancels one inline ask and returns its session pid."
  @spec cancel_inline_ask(EditorState.t(), pid() | nil) :: {EditorState.t(), pid() | nil}
  def cancel_inline_ask(%EditorState{} = state, buffer_pid) do
    shell_state = Runtime.state(state.shell_runtime)
    {shell_state, session_pid} = TraditionalState.cancel_inline_ask(shell_state, buffer_pid)

    runtime =
      Runtime.update_traditional_state(state.shell_runtime, fn _current -> shell_state end)

    {EditorState.apply_shell_runtime_transition(state, runtime), session_pid}
  end

  @doc "Activates or replaces one inline edit through its surface owner."
  @spec replace_inline_edit(EditorState.t(), InlineEdit.t()) :: EditorState.t()
  def replace_inline_edit(%EditorState{} = state, %InlineEdit{} = edit),
    do: update_traditional(state, &TraditionalState.replace_inline_edit(&1, edit))

  @doc "Cancels one inline edit and returns its session pid."
  @spec cancel_inline_edit(EditorState.t(), pid() | nil) :: {EditorState.t(), pid() | nil}
  def cancel_inline_edit(%EditorState{} = state, buffer_pid) do
    shell_state = Runtime.state(state.shell_runtime)
    {shell_state, session_pid} = TraditionalState.cancel_inline_edit(shell_state, buffer_pid)

    runtime =
      Runtime.update_traditional_state(state.shell_runtime, fn _current -> shell_state end)

    {EditorState.apply_shell_runtime_transition(state, runtime), session_pid}
  end

  @doc deprecated: "Use update_panel/2 or update_view/2 for targeted sub-struct updates"
  @doc "Updates the full agent UI state. Prefer update_panel/2 or update_view/2."
  @spec update_agent_ui(EditorState.t() | map(), (UIState.t() -> UIState.t())) ::
          EditorState.t() | map()
  def update_agent_ui(%EditorState{} = state, fun) do
    update_workspace_agent_ui(state, fun)
  end

  def update_agent_ui(%{workspace: %{agent_ui: a} = ws} = state, fun) do
    %{state | workspace: %{ws | agent_ui: fun.(a || UIState.new())}}
  end

  def update_agent_ui(%{agent_ui: a} = state, fun) do
    %{state | agent_ui: fun.(a)}
  end

  def update_agent_ui(state, _fun), do: state

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
  defp active_workspace_agent_ui(%EditorState{
         shell_runtime: %Runtime{state: %{tab_bar: %TabBar{} = tab_bar}}
       }) do
    case TabBar.active_workspace(tab_bar) do
      %Workspace{agent_ui: %UIState{} = agent_ui} -> agent_ui
      _ -> nil
    end
  end

  defp active_workspace_agent_ui(_state), do: nil

  @spec active_workspace_session(EditorState.t() | map()) :: pid() | nil
  defp active_workspace_session(%EditorState{
         shell_runtime: %Runtime{state: %{tab_bar: %TabBar{} = tab_bar}}
       }) do
    case TabBar.active_workspace(tab_bar) do
      %Workspace{session: session} when is_pid(session) -> session
      _ -> nil
    end
  end

  defp active_workspace_session(_state), do: nil

  @spec update_workspace_agent_ui(EditorState.t() | map(), (UIState.t() -> UIState.t())) ::
          EditorState.t() | map()
  defp update_workspace_agent_ui(
         %EditorState{
           shell_runtime: %Runtime{state: %{tab_bar: %TabBar{} = tab_bar}},
           workspace: %WorkspaceState{} = workspace
         } = state,
         fun
       ) do
    current_ui =
      active_workspace_agent_ui(state) || Map.get(workspace, :agent_ui) || UIState.new()

    next_ui = fun.(current_ui)

    tab_bar =
      case TabBar.active_workspace(tab_bar) do
        %Workspace{id: workspace_id} ->
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

  @spec update_traditional(EditorState.t(), (TraditionalState.t() -> TraditionalState.t())) ::
          EditorState.t()
  defp update_traditional(%EditorState{} = state, update) do
    runtime = Runtime.update_traditional_state(state.shell_runtime, update)
    EditorState.apply_shell_runtime_transition(state, runtime)
  end
end
