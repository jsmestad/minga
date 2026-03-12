defmodule Minga.Editor.State.AgentAccess do
  @moduledoc """
  Direct accessors for agent state on EditorState.

  Agent state (`agent`, `agentic`) lives as top-level fields on
  EditorState. This module provides read/write functions so callers
  don't need to know the field layout.

  All agent state access in the codebase goes through this module.
  """

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState

  # ── Readers ────────────────────────────────────────────────────────────────

  @doc "Returns the agent state."
  @spec agent(EditorState.t() | map()) :: AgentState.t()
  def agent(%EditorState{agent: a}), do: a
  def agent(%{agent: a}), do: a
  def agent(_), do: %AgentState{}

  @doc "Returns the agentic view state."
  @spec agentic(EditorState.t() | map()) :: ViewState.t()
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

  @doc "Updates agent state via a transform function."
  @spec update_agent(EditorState.t() | map(), (AgentState.t() -> AgentState.t())) ::
          EditorState.t() | map()
  def update_agent(%EditorState{agent: a} = state, fun) do
    %{state | agent: fun.(a)}
  end

  def update_agent(%{agent: a} = state, fun) do
    %{state | agent: fun.(a)}
  end

  @doc "Updates agentic view state via a transform function."
  @spec update_agentic(EditorState.t() | map(), (ViewState.t() -> ViewState.t())) ::
          EditorState.t() | map()
  def update_agentic(%EditorState{agentic: a} = state, fun) do
    %{state | agentic: fun.(a)}
  end

  def update_agentic(%{agentic: a} = state, fun) do
    %{state | agentic: fun.(a)}
  end
end
