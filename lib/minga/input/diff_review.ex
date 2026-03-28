defmodule Minga.Input.DiffReview do
  @moduledoc """
  Input handler for the diff review sub-state (y/x/Y/X).

  Active when the agentic view is in `:file_viewer` focus with a
  diff preview and the panel input is not focused. Handles y (accept
  hunk), x (reject hunk), Y (accept all), X (reject all), and passes
  navigation keys through to the scope trie.
  """

  @behaviour Minga.Input.Handler

  @type state :: Minga.Input.Handler.handler_state()

  alias Minga.Agent.View.Preview
  alias Minga.Editor.Commands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Keymap

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: Minga.Input.Handler.result()
  def handle_key(state, cp, _mods) do
    view = AgentAccess.view(state)
    panel = AgentAccess.panel(state)

    if view.focus == :file_viewer and
         match?(%Preview{content: {:diff, _}}, view.preview) and
         not panel.input_focused do
      dispatch_diff_key(state, cp)
    else
      {:passthrough, state}
    end
  end

  @spec dispatch_diff_key(EditorState.t(), non_neg_integer()) :: Minga.Input.Handler.result()
  defp dispatch_diff_key(state, ?y), do: {:handled, Commands.execute(state, :agent_accept_hunk)}
  defp dispatch_diff_key(state, ?x), do: {:handled, Commands.execute(state, :agent_reject_hunk)}

  defp dispatch_diff_key(state, ?Y),
    do: {:handled, Commands.execute(state, :agent_accept_all_hunks)}

  defp dispatch_diff_key(state, ?X),
    do: {:handled, Commands.execute(state, :agent_reject_all_hunks)}

  # Navigation keys still work during diff review: pass through to scope
  defp dispatch_diff_key(state, cp) do
    key = {cp, 0}

    case Keymap.resolve_scoped_key(:agent, :normal, key) do
      {:command, command} -> {:handled, Commands.execute(state, command)}
      {:prefix, _node} -> {:handled, state}
      :not_found -> {:handled, state}
    end
  end
end
