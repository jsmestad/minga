defmodule Minga.Input.AgentSearch do
  @moduledoc """
  Input handler for the agent chat search sub-state.

  Pushed onto the focus stack when `/` activates search in the
  agentic view. Captures all keys for search input (printable chars,
  Enter, Escape, Backspace) and pops itself when search is
  cancelled or submitted.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  def handle_key(state, cp, _mods) do
    view = AgentAccess.view(state)

    if view.search && view.search.input_active do
      {:handled, AgentCommands.handle_search_key(state, cp)}
    else
      {:passthrough, state}
    end
  end
end
