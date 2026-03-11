defmodule Minga.Surface.AgentView.Bridge do
  @moduledoc """
  Temporary bridge between `EditorState` and `AgentView.State`.

  During Phase 2 of the Surface extraction, the Editor still owns the
  `agent` and `agentic` fields on EditorState. This module copies them
  into an `AgentView.State` struct before each surface call and writes
  the results back afterward.

  This dual-ownership is scaffolding that goes away when EditorState
  shrinks and surfaces own their state directly.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Surface.AgentView.State, as: AgentViewState
  alias Minga.Surface.Context

  @doc """
  Extracts an `AgentView.State` from the current `EditorState`.
  """
  @spec from_editor_state(EditorState.t()) :: AgentViewState.t()
  def from_editor_state(%EditorState{} = es) do
    %AgentViewState{
      agent: es.agent,
      agentic: es.agentic,
      context: Context.from_editor_state(es)
    }
  end

  @doc """
  Writes `AgentView.State` fields back onto the `EditorState`.

  Only overwrites the fields that AgentView owns (agent, agentic).
  Buffer-related fields, shared infrastructure, and transient fields
  are untouched.
  """
  @spec to_editor_state(EditorState.t(), AgentViewState.t()) :: EditorState.t()
  def to_editor_state(%EditorState{} = es, %AgentViewState{} = av) do
    es = %{
      es
      | agent: av.agent,
        agentic: av.agentic
    }

    if av.context do
      Context.to_editor_state(es, av.context)
    else
      es
    end
  end
end
