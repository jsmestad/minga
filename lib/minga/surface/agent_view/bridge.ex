defmodule Minga.Surface.AgentView.Bridge do
  @moduledoc """
  Bridge between `EditorState` and `AgentView.State`.

  Builds an `AgentView.State` from the current `EditorState` for surface
  callbacks, and writes context changes back afterward. Agent-specific
  fields (`agent`, `agentic`) are read from `AgentAccess` (which checks
  `surface_state` first, then falls back to background tabs).
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Surface.AgentView.State, as: AgentViewState
  alias Minga.Surface.Context

  @doc """
  Extracts an `AgentView.State` from the current `EditorState`.
  """
  @spec from_editor_state(EditorState.t()) :: AgentViewState.t()
  def from_editor_state(%EditorState{} = es) do
    %AgentViewState{
      agent: AgentAccess.agent(es),
      agentic: AgentAccess.agentic(es),
      context: Context.from_editor_state(es)
    }
  end

  @doc """
  Writes `AgentView.State` fields back onto the `EditorState`.

  Updates the top-level agent and agentic fields, and writes any
  context changes (layout cache, click regions) back to EditorState.
  """
  @spec to_editor_state(EditorState.t(), AgentViewState.t()) :: EditorState.t()
  def to_editor_state(%EditorState{} = es, %AgentViewState{} = av) do
    es = %{es | agent: av.agent, agentic: av.agentic}

    if av.context do
      Context.to_editor_state(es, av.context)
    else
      es
    end
  end
end
