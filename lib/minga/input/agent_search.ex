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

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  def handle_key(%{agentic: %{search: %{input_active: true}}} = state, cp, _mods) do
    {:handled, AgentCommands.handle_search_key(state, cp)}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
