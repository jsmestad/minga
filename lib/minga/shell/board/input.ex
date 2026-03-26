defmodule Minga.Shell.Board.Input do
  @moduledoc """
  Input handler for The Board grid view.

  Active only when Shell.Board is the active shell and the grid is
  showing (not zoomed into a card). Handles:

  - Arrow keys / h,j,k,l: navigate between cards
  - Enter: zoom into the focused card
  - Escape / q: switch back to Shell.Traditional
  - n: dispatch a new agent (opens the dispatch prompt)

  All other keys pass through to global bindings (Ctrl+Q, Ctrl+S, etc.).
  When zoomed into a card, this handler is not in the stack; the
  Traditional handler stack takes over.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.State, as: EditorState
  alias Minga.Shell.Board
  alias Minga.Shell.Board.State, as: BoardState

  # ── Key constants ──────────────────────────────────────────────────────

  # Vim navigation
  @key_h ?h
  @key_j ?j
  @key_k ?k
  @key_l ?l

  # Actions
  @key_enter 13
  @key_escape 27
  @key_q ?q
  @key_n ?n

  # Kitty keyboard protocol arrow keys
  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_left 57_350
  @arrow_right 57_351

  # macOS NSEvent arrow keys (GUI frontend)
  @ns_up 0xF700
  @ns_down 0xF701
  @ns_left 0xF702
  @ns_right 0xF703

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()

  # Only active when Board shell is showing the grid
  def handle_key(%{shell: Board, shell_state: %BoardState{zoomed_into: nil}} = state, cp, mods) do
    dispatch_grid_key(state, cp, mods)
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  # ── Grid key dispatch ──────────────────────────────────────────────────

  @spec dispatch_grid_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()

  # Navigation: move focus between cards
  defp dispatch_grid_key(state, cp, _mods) when cp in [@key_j, @arrow_down, @ns_down] do
    {:handled, move_focus(state, :down)}
  end

  defp dispatch_grid_key(state, cp, _mods) when cp in [@key_k, @arrow_up, @ns_up] do
    {:handled, move_focus(state, :up)}
  end

  defp dispatch_grid_key(state, cp, _mods) when cp in [@key_l, @arrow_right, @ns_right] do
    {:handled, move_focus(state, :right)}
  end

  defp dispatch_grid_key(state, cp, _mods) when cp in [@key_h, @arrow_left, @ns_left] do
    {:handled, move_focus(state, :left)}
  end

  # Enter: zoom into the focused card
  defp dispatch_grid_key(state, @key_enter, _mods) do
    board = state.shell_state

    case BoardState.focused(board) do
      nil ->
        {:handled, state}

      _card ->
        {:handled, zoom_into_focused(state)}
    end
  end

  # n: dispatch a new agent
  defp dispatch_grid_key(state, @key_n, _mods) do
    {:handled, create_new_card(state)}
  end

  # Escape / q: no-op for now (Board is the root view)
  # TODO: switch to Shell.Traditional when shell switching is wired
  defp dispatch_grid_key(state, cp, _mods) when cp in [@key_escape, @key_q] do
    {:handled, state}
  end

  # Everything else passes through (Ctrl+Q quit, Ctrl+S save, etc.)
  defp dispatch_grid_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  # ── Actions ────────────────────────────────────────────────────────────

  @spec move_focus(EditorState.t(), :up | :down | :left | :right) :: EditorState.t()
  defp move_focus(state, direction) do
    board = state.shell_state
    # Use the grid columns from the last computed layout, default to 3
    cols = grid_cols(state)
    new_board = BoardState.move_focus(board, direction, cols)
    %{state | shell_state: new_board}
  end

  @spec zoom_into_focused(EditorState.t()) :: EditorState.t()
  defp zoom_into_focused(state) do
    board = state.shell_state
    card = BoardState.focused(board)

    if card do
      # Snapshot the current (minimal) workspace state onto the board
      # context, then restore the card's workspace as the live workspace
      workspace_snapshot = Map.from_struct(state.workspace)

      new_board = BoardState.zoom_into(board, card.id, workspace_snapshot)

      state = %{state | shell_state: new_board}

      # If the card has a stored workspace, restore it
      case card.workspace do
        nil ->
          state

        ws when is_map(ws) ->
          EditorState.restore_tab_context(state, ws)
      end
    else
      state
    end
  end

  @spec create_new_card(EditorState.t()) :: EditorState.t()
  defp create_new_card(state) do
    board = state.shell_state
    {new_board, _card} = BoardState.create_card(board, task: "New agent", status: :idle)
    %{state | shell_state: new_board}
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  @spec grid_cols(EditorState.t()) :: pos_integer()
  defp grid_cols(%{layout: %{grid_cols: cols}}) when is_integer(cols) and cols > 0, do: cols

  defp grid_cols(%{workspace: %{viewport: %{cols: vp_cols}}}) do
    # Estimate columns from viewport width (matching Layout computation)
    max(div(vp_cols, 26), 1)
  end

  defp grid_cols(_state), do: 3
end
