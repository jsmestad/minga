defmodule Minga.Surface.AgentView.State do
  @moduledoc """
  Internal state for the AgentView surface.

  Groups all agent/agentic concerns that were previously spread across
  `EditorState.agent` and `EditorState.agentic`. The struct has two
  main sub-structs:

  1. **`agent`** — session lifecycle, status, panel UI, pending approval,
     buffer, spinner, session history (`Minga.Editor.State.Agent`).
  2. **`agentic`** — view state: focus, preview, search, toast, diff
     baselines, chat width, help visibility (`Minga.Agent.View.State`).

  ## Relationship to EditorState

  During Phase 2 of the Surface extraction, a bridge layer copies
  `state.agent` and `state.agentic` between `EditorState` and this
  struct. This dual-ownership is temporary scaffolding.
  """

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Surface.Context

  @type t :: %__MODULE__{
          agent: AgentState.t(),
          agentic: ViewState.t(),
          context: Context.t() | nil
        }

  @enforce_keys [:agent, :agentic]
  defstruct agent: nil,
            agentic: nil,
            context: nil
end
