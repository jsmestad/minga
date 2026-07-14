defmodule MingaEditor.Shell.Traditional.Workflow do
  @moduledoc """
  Installs values produced by named Traditional shell transitions at the
  editor workflow boundary.
  """

  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.State.InlineEdit
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace

  @spec install_traditional_state(EditorState.t(), TraditionalState.t()) :: EditorState.t()
  defp install_traditional_state(%EditorState{} = state, %TraditionalState{} = shell_state) do
    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  @doc "Installs the active Traditional agent presentation and its workspace mirror."
  @spec install_agent_ui(EditorState.t(), UIState.t()) :: EditorState.t()
  def install_agent_ui(
        %EditorState{shell_runtime: %Runtime{state: %TraditionalState{}}} = state,
        %UIState{} = agent_ui
      ) do
    shell_state = Runtime.state(state.shell_runtime)

    shell_state =
      case TraditionalState.tab_bar(shell_state) do
        %TabBar{} = tab_bar ->
          tab_bar =
            case TabBar.active_workspace(tab_bar) do
              %Workspace{id: workspace_id} ->
                TabBar.update_workspace(
                  tab_bar,
                  workspace_id,
                  &Workspace.set_agent_ui(&1, agent_ui)
                )

              _ ->
                tab_bar
            end

          TraditionalState.install_tab_bar(shell_state, tab_bar)

        _ ->
          shell_state
      end

    state
    |> install_traditional_state(shell_state)
    |> then(&%{&1 | workspace: SessionState.set_agent_ui(&1.workspace, agent_ui)})
  end

  def install_agent_ui(%EditorState{} = state, %UIState{} = agent_ui),
    do: %{state | workspace: SessionState.set_agent_ui(state.workspace, agent_ui)}

  @doc "Sets the active agent status through its owning shell state."
  @spec install_agent_status(EditorState.t(), AgentState.status()) :: EditorState.t()
  def install_agent_status(%EditorState{} = state, status),
    do: transition_agent(state, &AgentState.set_status(&1, status))

  @doc "Starts the active agent spinner."
  @spec install_agent_spinner_start(EditorState.t()) :: EditorState.t()
  def install_agent_spinner_start(%EditorState{} = state),
    do: transition_agent(state, &AgentState.start_spinner_timer/1)

  @doc "Stops the active agent spinner."
  @spec install_agent_spinner_stop(EditorState.t()) :: EditorState.t()
  def install_agent_spinner_stop(%EditorState{} = state),
    do: transition_agent(state, &AgentState.stop_spinner_timer/1)

  @doc "Resets active agent presentation cache."
  @spec install_agent_cache_reset(EditorState.t()) :: EditorState.t()
  def install_agent_cache_reset(%EditorState{} = state),
    do: transition_agent(state, &AgentState.reset_cache/1)

  @doc "Sets the active agent tool name."
  @spec install_agent_tool(EditorState.t(), String.t() | nil) :: EditorState.t()
  def install_agent_tool(%EditorState{} = state, name),
    do: transition_agent(state, &AgentState.set_active_tool_name(&1, name))

  @doc "Clears the active agent tool name."
  @spec install_agent_tool_clear(EditorState.t()) :: EditorState.t()
  def install_agent_tool_clear(%EditorState{} = state),
    do: transition_agent(state, &AgentState.clear_active_tool_name/1)

  @doc "Sets the active agent error."
  @spec install_agent_error(EditorState.t(), String.t() | nil) :: EditorState.t()
  def install_agent_error(%EditorState{} = state, message),
    do: transition_agent(state, &AgentState.set_error(&1, message))

  @doc "Sets pending agent approval."
  @spec install_agent_approval(EditorState.t(), AgentState.approval()) :: EditorState.t()
  def install_agent_approval(%EditorState{} = state, approval),
    do: transition_agent(state, &AgentState.set_pending_approval(&1, approval))

  @doc "Clears pending agent approval."
  @spec clear_agent_approval(EditorState.t()) :: EditorState.t()
  def clear_agent_approval(%EditorState{} = state),
    do: transition_agent(state, &AgentState.clear_pending_approval/1)

  @doc "Engages active agent chat auto-scroll."
  @spec engage_agent_scroll(EditorState.t()) :: EditorState.t()
  def engage_agent_scroll(%EditorState{} = state),
    do: install_agent_ui(state, UIState.engage_auto_scroll(state.workspace.agent_ui))

  @doc "Re-evaluates active agent chat auto-scroll."
  @spec maybe_agent_auto_scroll(EditorState.t()) :: EditorState.t()
  def maybe_agent_auto_scroll(%EditorState{} = state),
    do: install_agent_ui(state, UIState.maybe_auto_scroll(state.workspace.agent_ui))

  @doc "Installs a changed Traditional agent lifecycle value."
  @spec install_agent_state(EditorState.t(), AgentState.t()) :: EditorState.t()
  def install_agent_state(
        %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}} = state,
        %AgentState{} = agent
      ) do
    install_traditional_state(state, TraditionalState.replace_agent(shell_state, agent))
  end

  def install_agent_state(%EditorState{} = state, %AgentState{}), do: state

  @spec transition_agent(EditorState.t(), (AgentState.t() -> AgentState.t())) :: EditorState.t()
  defp transition_agent(
         %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}} = state,
         transition
       ) do
    install_agent_state(state, transition.(TraditionalState.agent(shell_state)))
  end

  defp transition_agent(%EditorState{} = state, _transition), do: state

  @doc "Installs a changed active agent panel."
  @spec install_agent_panel(EditorState.t(), Panel.t()) :: EditorState.t()
  def install_agent_panel(%EditorState{} = state, %Panel{} = panel) do
    install_agent_ui(state, UIState.replace_panel(state.workspace.agent_ui, panel))
  end

  @doc "Installs a changed active agent view."
  @spec install_agent_view(EditorState.t(), View.t()) :: EditorState.t()
  def install_agent_view(%EditorState{} = state, %View{} = view) do
    install_agent_ui(state, UIState.replace_view(state.workspace.agent_ui, view))
  end

  @doc "Installs an inline ask on the active Traditional shell."
  @spec install_inline_ask(EditorState.t(), InlineAsk.t()) :: EditorState.t()
  def install_inline_ask(%EditorState{} = state, %InlineAsk{} = ask) do
    shell_state = TraditionalState.replace_inline_ask(Runtime.state(state.shell_runtime), ask)
    install_traditional_state(state, shell_state)
  end

  @doc "Cancels an inline ask on the active Traditional shell."
  @spec cancel_inline_ask(EditorState.t(), pid() | nil) :: {EditorState.t(), pid() | nil}
  def cancel_inline_ask(%EditorState{} = state, buffer_pid) do
    {shell_state, session_pid} =
      TraditionalState.cancel_inline_ask(Runtime.state(state.shell_runtime), buffer_pid)

    {install_traditional_state(state, shell_state), session_pid}
  end

  @doc "Installs an inline edit on the active Traditional shell."
  @spec install_inline_edit(EditorState.t(), InlineEdit.t()) :: EditorState.t()
  def install_inline_edit(%EditorState{} = state, %InlineEdit{} = edit) do
    shell_state = TraditionalState.replace_inline_edit(Runtime.state(state.shell_runtime), edit)
    install_traditional_state(state, shell_state)
  end

  @doc "Cancels an inline edit on the active Traditional shell."
  @spec cancel_inline_edit(EditorState.t(), pid() | nil) :: {EditorState.t(), pid() | nil}
  def cancel_inline_edit(%EditorState{} = state, buffer_pid) do
    {shell_state, session_pid} =
      TraditionalState.cancel_inline_edit(Runtime.state(state.shell_runtime), buffer_pid)

    {install_traditional_state(state, shell_state), session_pid}
  end
end
