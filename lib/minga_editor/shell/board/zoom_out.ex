defmodule MingaEditor.Shell.Board.ZoomOut do
  @moduledoc """
  Input handler that intercepts Escape to zoom out of a card.

  Sits at the top of the surface handler stack when zoomed into a card.
  Catches Escape before the Traditional handlers see it, snapshots the
  current workspace back onto the card, and returns to the grid view.

  All other keys pass through to the Traditional handler stack below.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Workspace.State, as: WorkspaceState
  alias MingaEditor.Shell.Board
  alias MingaEditor.Shell.Board.AgentDeactivation
  alias MingaEditor.Shell.Board.Card
  alias MingaEditor.Shell.Board.State, as: BoardState

  @key_escape 27

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  # Escape or q when zoomed: zoom out back to the grid.
  # Leader sequences must keep flowing to the normal handler stack, so they
  # always pass through before zoom-out gets a chance to run.
  # When the agent panel is focused, let the key pass through so the prompt
  # handler can apply its own normal/visual/operator semantics first.
  def handle_key(%{shell: Board} = state, cp, mods) do
    if Minga.Editing.in_leader?(state) do
      {:passthrough, state}
    else
      handle_zoomed_key(state, cp, mods)
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  defp handle_zoomed_key(%{shell_state: %BoardState{zoomed_into: card_id}} = state, cp, 0)
       when card_id != nil and cp in [@key_escape, ?q] do
    if agent_panel_focused?(state) do
      {:passthrough, state}
    else
      {:handled, zoom_out(state)}
    end
  end

  defp handle_zoomed_key(state, _cp, _mods), do: {:passthrough, state}

  # Returns true when the agent panel is focused.
  # In this state, ESC should be handled by the prompt stack, not zoom out.
  @spec agent_panel_focused?(EditorState.t()) :: boolean()
  defp agent_panel_focused?(state) do
    state.workspace.keymap_scope == :agent and
      state.workspace.agent_ui.panel.input_focused
  end

  # ── Zoom out ───────────────────────────────────────────────────────────

  @spec zoom_out(EditorState.t()) :: EditorState.t()
  defp zoom_out(state) do
    board = state.shell_state
    card_id = board.zoomed_into

    # The card currently holds the "board grid" workspace snapshot
    # (stored by zoom_into). Swap: put the live workspace on the card,
    # get the grid workspace back.
    card = Map.get(board.cards, card_id)
    grid_workspace = if card, do: card.workspace, else: nil

    # Store the live (zoomed) workspace onto the card for next zoom-in
    live_workspace = WorkspaceState.to_tab_context(state.workspace)

    board =
      BoardState.update_card(board, card_id, fn c ->
        Card.store_workspace(c, live_workspace)
      end)

    # Clear zoom state
    board = %{board | zoomed_into: nil}
    state = %{state | shell_state: board}

    # Reset the shell-level agent rendering cache before restoring the grid
    # workspace so the grid does not render against the previous card's
    # status, error, or pending approval.
    state = AgentDeactivation.deactivate_agent_for_card(state)

    # Restore the grid workspace if we have one. The restore replaces the
    # workspace fields wholesale, so workspace-level activation state
    # (keymap scope, agent_ui focus) is reset by the restore itself.
    if grid_workspace && is_map(grid_workspace) && map_size(grid_workspace) > 0 do
      EditorState.restore_tab_context(state, grid_workspace)
    else
      state
    end
  end
end
