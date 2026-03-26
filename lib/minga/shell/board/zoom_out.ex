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

    # Snapshot the live workspace onto the card before leaving
    workspace_snapshot = Map.from_struct(state.workspace)

    board = BoardState.update_card(board, card_id, fn card ->
      Card.store_workspace(card, workspace_snapshot)
    end)

    # Clear zoom state
    board = %{board | zoomed_into: nil}

    %{state | shell_state: board}
  end
end
