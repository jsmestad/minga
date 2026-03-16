defmodule Minga.Editor.State.AgentAccess do
  @moduledoc """
  Direct accessors for agent state on EditorState.

  Agent state (`agent`, `agent_ui`) lives as top-level fields on
  EditorState. This module provides read/write functions so callers
  don't need to know the field layout.

  All agent state access in the codebase goes through this module.
  """

  alias Minga.Agent.UIState
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState

  # ── Readers ────────────────────────────────────────────────────────────────

  @doc "Returns the agent state."
  @spec agent(EditorState.t() | map()) :: AgentState.t()
  def agent(%EditorState{agent: a}), do: a
  def agent(%{agent: a}), do: a
  def agent(_), do: %AgentState{}

  @doc "Returns the agent UI state."
  @spec agent_ui(EditorState.t() | map()) :: UIState.t()
  def agent_ui(%EditorState{agent_ui: a}), do: a
  def agent_ui(%{agent_ui: a}), do: a
  def agent_ui(_), do: UIState.new()

  @doc "Returns the agent session pid, or nil."
  @spec session(EditorState.t() | map()) :: pid() | nil
  def session(state), do: agent(state).session

  @doc "Returns the agent panel state."
  @spec panel(EditorState.t() | map()) :: UIState.t()
  def panel(state), do: agent_ui(state)

  @doc "Returns true if the agent panel input is focused."
  @spec input_focused?(EditorState.t() | map()) :: boolean()
  def input_focused?(state), do: agent_ui(state).input_focused

  @doc "Returns the agent UI focus."
  @spec focus(EditorState.t() | map()) :: atom()
  def focus(state), do: agent_ui(state).focus

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

  @doc "Updates agent UI state via a transform function."
  @spec update_agent_ui(EditorState.t() | map(), (UIState.t() -> UIState.t())) ::
          EditorState.t() | map()
  def update_agent_ui(%EditorState{agent_ui: a} = state, fun) do
    %{state | agent_ui: fun.(a)}
  end

  def update_agent_ui(%{agent_ui: a} = state, fun) do
    %{state | agent_ui: fun.(a)}
  end
end
