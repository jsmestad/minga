defmodule Minga.Shell.Board.ZoomOut do
  @moduledoc """
  Input handler that intercepts Escape to zoom out of a card.

  Sits at the top of the surface handler stack when zoomed into a card.
  Catches Escape before the Traditional handlers see it, snapshots the
  current workspace back onto the card, and returns to the grid view.

  All other keys pass through to the Traditional handler stack below.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.State, as: EditorState
  alias Minga.Shell.Board
  alias Minga.Shell.Board.Card
  alias Minga.Shell.Board.State, as: BoardState

  @key_escape 27

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()

  # Escape when zoomed: zoom out back to the grid
  def handle_key(
        %{shell: Board, shell_state: %BoardState{zoomed_into: card_id}} = state,
        @key_escape,
        0
      )
      when card_id != nil do
    # Don't intercept Escape if a modal overlay is open (picker, completion, etc.)
    # Those are handled by overlay handlers above us in the stack.
    # We only get here if overlays passed through.
    {:handled, zoom_out(state)}
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

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
    live_workspace = Map.from_struct(state.workspace)

    board = BoardState.update_card(board, card_id, fn c ->
      Card.store_workspace(c, live_workspace)
    end)

    # Clear zoom state
    board = %{board | zoomed_into: nil}
    state = %{state | shell_state: board}

    # Restore the grid workspace if we have one
    if grid_workspace && is_map(grid_workspace) && map_size(grid_workspace) > 0 do
      EditorState.restore_tab_context(state, grid_workspace)
    else
      state
    end
  end
end
