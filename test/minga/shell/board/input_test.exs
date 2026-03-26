defmodule Minga.Shell.Board.InputTest do
  @moduledoc """
  Tests for Board input handlers: grid navigation, zoom in/out, dispatch.

  Follows the Dashboard test pattern: builds a minimal EditorState with
  Board shell state and calls handler functions directly. No GenServer.
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Shell.Board
  alias Minga.Shell.Board.Input, as: BoardInput
  alias Minga.Shell.Board.State, as: BoardState
  alias Minga.Shell.Board.ZoomOut

  # ── Key constants ──────────────────────────────────────────────────────

  @arrow_down 57_353
  @arrow_right 57_351
  @enter 13
  @escape 27

  # ── Helpers ────────────────────────────────────────────────────────────

  defp board_state_with_cards(0), do: BoardState.new()

  defp board_state_with_cards(count) when count > 0 do
    Enum.reduce(1..count, BoardState.new(), fn i, acc ->
      {acc, _card} = BoardState.create_card(acc, task: "Task #{i}")
      acc
    end)
  end

  defp editor_with_board(card_count) do
    board = board_state_with_cards(card_count)

    %EditorState{
      port_manager: self(),
      shell: Board,
      shell_state: board,
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80)
      },
      focus_stack: [BoardInput, Minga.Input.GlobalBindings]
    }
  end

  defp editor_zoomed_into(card_count, card_id) do
    state = editor_with_board(card_count)
    board = BoardState.zoom_into(state.shell_state, card_id, %{fake: :workspace})
    %{state | shell_state: board}
  end

  # ── Grid navigation ────────────────────────────────────────────────────

  describe "grid navigation" do
    test "j / arrow down moves focus down" do
      state = editor_with_board(4)
      first_id = state.shell_state.focused_card

      {:handled, new_state} = BoardInput.handle_key(state, ?j, 0)
      assert new_state.shell_state.focused_card != first_id

      # Arrow down does the same thing
      state2 = editor_with_board(4)
      {:handled, new_state2} = BoardInput.handle_key(state2, @arrow_down, 0)
      assert new_state2.shell_state.focused_card == new_state.shell_state.focused_card
    end

    test "k / arrow up moves focus up" do
      state = editor_with_board(4)
      # Focus the second card first
      board = BoardState.focus_card(state.shell_state, 2)
      state = %{state | shell_state: board}

      {:handled, new_state} = BoardInput.handle_key(state, ?k, 0)
      assert new_state.shell_state.focused_card == 1
    end

    test "l / arrow right moves focus right" do
      state = editor_with_board(4)

      {:handled, new_state} = BoardInput.handle_key(state, ?l, 0)
      assert new_state.shell_state.focused_card == 2

      # Arrow does the same
      state2 = editor_with_board(4)
      {:handled, new_state2} = BoardInput.handle_key(state2, @arrow_right, 0)
      assert new_state2.shell_state.focused_card == 2
    end

    test "h / arrow left moves focus left" do
      state = editor_with_board(4)
      board = BoardState.focus_card(state.shell_state, 2)
      state = %{state | shell_state: board}

      {:handled, new_state} = BoardInput.handle_key(state, ?h, 0)
      assert new_state.shell_state.focused_card == 1
    end

    test "navigation clamps at boundaries" do
      state = editor_with_board(1)

      {:handled, new_state} = BoardInput.handle_key(state, ?j, 0)
      assert new_state.shell_state.focused_card == 1

      {:handled, new_state} = BoardInput.handle_key(state, ?h, 0)
      assert new_state.shell_state.focused_card == 1
    end
  end

  # ── Zoom in ────────────────────────────────────────────────────────────

  describe "Enter zooms into focused card" do
    test "sets zoomed_into on the board state" do
      state = editor_with_board(3)
      focused_id = state.shell_state.focused_card

      {:handled, new_state} = BoardInput.handle_key(state, @enter, 0)
      assert new_state.shell_state.zoomed_into == focused_id
    end

    test "no-ops when no card is focused" do
      state = editor_with_board(0)
      # Empty board, no focus
      assert state.shell_state.focused_card == nil

      {:handled, new_state} = BoardInput.handle_key(state, @enter, 0)
      assert new_state.shell_state.zoomed_into == nil
    end
  end

  # ── Zoom out ───────────────────────────────────────────────────────────

  describe "Escape zooms out when zoomed" do
    test "clears zoomed_into and snapshots workspace" do
      state = editor_zoomed_into(3, 1)
      assert state.shell_state.zoomed_into == 1

      {:handled, new_state} = ZoomOut.handle_key(state, @escape, 0)
      assert new_state.shell_state.zoomed_into == nil
      # Workspace was stored on the card
      assert new_state.shell_state.cards[1].workspace != nil
    end

    test "passes through when not zoomed" do
      state = editor_with_board(3)
      assert state.shell_state.zoomed_into == nil

      {:passthrough, _state} = ZoomOut.handle_key(state, @escape, 0)
    end

    test "passes through for non-Escape keys when zoomed" do
      state = editor_zoomed_into(3, 1)

      {:passthrough, _state} = ZoomOut.handle_key(state, ?a, 0)
    end
  end

  # ── New card dispatch ──────────────────────────────────────────────────

  describe "n dispatches new card" do
    test "creates a new card on the board" do
      state = editor_with_board(2)
      initial_count = BoardState.card_count(state.shell_state)

      {:handled, new_state} = BoardInput.handle_key(state, ?n, 0)
      assert BoardState.card_count(new_state.shell_state) == initial_count + 1
    end
  end

  # ── Passthrough ────────────────────────────────────────────────────────

  describe "passthrough" do
    test "unbound keys without modifiers are consumed (no vim fallthrough)" do
      state = editor_with_board(3)

      {:handled, _state} = BoardInput.handle_key(state, ?x, 0)
      {:handled, _state} = BoardInput.handle_key(state, ?z, 0)
    end

    test "Ctrl-modified keys pass through to GlobalBindings" do
      state = editor_with_board(3)

      {:passthrough, _state} = BoardInput.handle_key(state, ?q, 0x02)
      {:passthrough, _state} = BoardInput.handle_key(state, ?s, 0x02)
    end

    test "handler passes through when shell is not Board" do
      state = %EditorState{
        port_manager: self(),
        shell: Minga.Shell.Traditional,
        shell_state: %Minga.Shell.Traditional.State{},
        workspace: %Minga.Workspace.State{viewport: Viewport.new(24, 80)},
        focus_stack: []
      }

      {:passthrough, _state} = BoardInput.handle_key(state, ?j, 0)
    end

    test "handler passes through when zoomed (ZoomOut handles Escape)" do
      state = editor_zoomed_into(3, 1)

      # Board.Input should passthrough since we're zoomed
      {:passthrough, _state} = BoardInput.handle_key(state, ?j, 0)
    end
  end
end
