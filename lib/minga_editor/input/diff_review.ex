defmodule MingaEditor.Input.DiffReview do
  @moduledoc """
  Input handler for the diff review sub-state (y/x/Y/X).

  Active when the agentic view is in `:file_viewer` focus with a
  diff preview, the panel input is not focused, and no command line or
  key sequence owns the key. Handles y (accept
  hunk), x (reject hunk), Y (accept all), X (reject all), and passes
  navigation keys through to the scope trie.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, cp, mods) do
    view = state.workspace.agent_ui.view
    panel = state.workspace.agent_ui.panel

    # An open command line or pending sequence owns every key, so `:x` or
    # `SPC h k y` never accepts or rejects a hunk.
    if View.focus(view) == :file_viewer and
         match?(%Preview{content: {:diff, _}}, view.preview) and
         not panel.input_focused and not Minga.Editing.owns_next_key?(state) do
      dispatch_diff_key(state, cp, mods)
    else
      {:passthrough, state}
    end
  end

  @spec dispatch_diff_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp dispatch_diff_key(state, ?y, 0),
    do: {:handled, Commands.execute(state, :agent_accept_hunk)}

  defp dispatch_diff_key(state, ?x, 0),
    do: {:handled, Commands.execute(state, :agent_reject_hunk)}

  defp dispatch_diff_key(state, ?Y, 0),
    do: {:handled, Commands.execute(state, :agent_accept_all_hunks)}

  defp dispatch_diff_key(state, ?X, 0),
    do: {:handled, Commands.execute(state, :agent_reject_all_hunks)}

  defp dispatch_diff_key(state, _cp, _mods), do: {:passthrough, state}
end
