defmodule Minga.Editor.State.AgentAccess do
  @moduledoc """
  Surface-aware accessors for agent state on EditorState.

  Agent state lives inside the `surface_state` when the active surface
  is AgentView, or in a background agent tab's stored context when the
  active surface is BufferView (editor scope with side panel).

  This module provides get/set functions that read from and write to
  the correct location based on the active surface. All agent state
  access in the codebase goes through this module.
  """

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Surface.AgentView.State, as: AVState

  # ── Readers ────────────────────────────────────────────────────────────────

  @doc "Returns the agent state from the active surface or background tab."
  @spec agent(EditorState.t() | map()) :: AgentState.t()
  def agent(%EditorState{surface_state: %AVState{agent: a}}), do: a
  def agent(%EditorState{agent: a}), do: a
  def agent(%{agent: a}), do: a
  def agent(_), do: %AgentState{}

  @doc "Returns the agentic view state from the active surface or background tab."
  @spec agentic(EditorState.t() | map()) :: ViewState.t()
  def agentic(%EditorState{surface_state: %AVState{agentic: a}}), do: a
  def agentic(%EditorState{agentic: a}), do: a
  def agentic(%{agentic: a}), do: a
  def agentic(_), do: ViewState.new()

  @doc "Returns the agent session pid, or nil."
  @spec session(EditorState.t() | map()) :: pid() | nil
  def session(state), do: agent(state).session

  @doc "Returns the agent panel state."
  @spec panel(EditorState.t() | map()) :: Minga.Agent.PanelState.t()
  def panel(state), do: agent(state).panel

  @doc "Returns true if the agent panel input is focused."
  @spec input_focused?(EditorState.t() | map()) :: boolean()
  def input_focused?(state), do: agent(state).panel.input_focused

  @doc "Returns the agentic view focus."
  @spec focus(EditorState.t() | map()) :: atom()
  def focus(state), do: agentic(state).focus

  # ── Writers ────────────────────────────────────────────────────────────────

  @doc """
  Updates agent state. Writes to the correct location based on surface.

  When AgentView is active, writes to both `surface_state` and the
  EditorState `agent` field (dual-write for migration safety). When
  BufferView is active, writes to the EditorState `agent` field (which
  will be replaced by background tab writes once the field is removed).
  """
  @spec update_agent(EditorState.t() | map(), (AgentState.t() -> AgentState.t())) ::
          EditorState.t() | map()
  def update_agent(%EditorState{surface_state: %AVState{} = av} = state, fun) do
    new_agent = fun.(av.agent)
    new_av = %{av | agent: new_agent}
    %{state | agent: new_agent, surface_state: new_av}
  end

  def update_agent(%EditorState{} = state, fun) do
    %{state | agent: fun.(state.agent)}
  end

  # Bare map fallback (for tests and slash commands that use plain maps)
  def update_agent(%{agent: agent} = state, fun) do
    %{state | agent: fun.(agent)}
  end

  @doc """
  Updates agentic view state. Writes to the correct location based on surface.
  """
  @spec update_agentic(EditorState.t() | map(), (ViewState.t() -> ViewState.t())) ::
          EditorState.t() | map()
  def update_agentic(%EditorState{surface_state: %AVState{} = av} = state, fun) do
    new_agentic = fun.(av.agentic)
    new_av = %{av | agentic: new_agentic}
    %{state | agentic: new_agentic, surface_state: new_av}
  end

  def update_agentic(%EditorState{} = state, fun) do
    %{state | agentic: fun.(state.agentic)}
  end

  # Bare map fallback
  def update_agentic(%{agentic: agentic} = state, fun) do
    %{state | agentic: fun.(agentic)}
  end

  # ── Tab-based lookups ──────────────────────────────────────────────────────

  @doc """
  Returns the agent state from the nearest agent tab's stored surface_state.

  Used when the active surface is BufferView (editor scope with side panel)
  and agent state isn't on the live EditorState. Falls back to a default
  AgentState if no agent tab exists.
  """
  @spec agent_from_tab(EditorState.t()) :: AgentState.t()
  def agent_from_tab(%EditorState{tab_bar: %TabBar{} = tb}) do
    case find_agent_tab(tb) do
      %{context: %{surface_state: %AVState{agent: a}}} -> a
      _ -> %AgentState{}
    end
  end

  def agent_from_tab(_), do: %AgentState{}

  @doc """
  Returns the agentic view state from the nearest agent tab's stored surface_state.
  """
  @spec agentic_from_tab(EditorState.t()) :: ViewState.t()
  def agentic_from_tab(%EditorState{tab_bar: %TabBar{} = tb}) do
    case find_agent_tab(tb) do
      %{context: %{surface_state: %AVState{agentic: a}}} -> a
      _ -> ViewState.new()
    end
  end

  def agentic_from_tab(_), do: ViewState.new()

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec find_agent_tab(TabBar.t()) :: Tab.t() | nil
  defp find_agent_tab(tb), do: TabBar.find_by_kind(tb, :agent)
end
