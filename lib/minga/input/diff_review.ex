defmodule Minga.Input.DiffReview do
  @moduledoc """
  Input handler for the diff review sub-state (y/x/Y/X).

  Active when the agentic view is in `:file_viewer` focus with a
  diff preview and the panel input is not focused. Handles y (accept
  hunk), x (reject hunk), Y (accept all), X (reject all), and passes
  navigation keys through to the scope trie.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Agent.View.Preview
  alias Minga.Editor.Commands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Keymap.Scope

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  def handle_key(
        %{
          agentic: %{focus: :file_viewer, preview: %Preview{content: {:diff, _}}},
          agent: %{panel: %{input_focused: false}}
        } = state,
        cp,
        _mods
      ) do
    dispatch_diff_key(state, cp)
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  @spec dispatch_diff_key(EditorState.t(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  defp dispatch_diff_key(state, ?y), do: {:handled, Commands.execute(state, :agent_accept_hunk)}
  defp dispatch_diff_key(state, ?x), do: {:handled, Commands.execute(state, :agent_reject_hunk)}

  defp dispatch_diff_key(state, ?Y),
    do: {:handled, Commands.execute(state, :agent_accept_all_hunks)}

  defp dispatch_diff_key(state, ?X),
    do: {:handled, Commands.execute(state, :agent_reject_all_hunks)}

  # Navigation keys still work during diff review: pass through to scope
  defp dispatch_diff_key(state, cp) do
    key = {cp, 0}

    case Scope.resolve_key(:agent, :normal, key) do
      {:command, command} -> {:handled, Commands.execute(state, command)}
      {:prefix, _node} -> {:handled, state}
      :not_found -> {:handled, state}
    end
  end
end
