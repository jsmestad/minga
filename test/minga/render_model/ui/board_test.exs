defmodule Minga.RenderModel.UI.BoardTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Board
  alias Minga.RenderModel.UI.Board.Card

  describe "%Board{}" do
    test "requires visible? and cards" do
      assert_raise ArgumentError, fn -> struct!(Board, %{}) end
    end

    test "hidden/0 builds an empty, not-visible board" do
      board = Board.hidden()

      refute board.visible?
      assert board.cards == []
      assert board.zoomed_card_id == nil
    end
  end

  describe "zoomed_card/1" do
    test "returns nil when no card is zoomed" do
      assert Board.zoomed_card(%Board{visible?: true, cards: [], zoomed_card_id: nil}) == nil
    end

    test "returns the card matching zoomed_card_id" do
      card = %Card{
        id: 7,
        status: :working,
        kind: :agent,
        task: "t",
        display_task: "t",
        created_at: DateTime.from_unix!(0)
      }

      board = %Board{visible?: true, zoomed_card_id: 7, cards: [card]}

      assert Board.zoomed_card(board) == card
    end
  end

  describe "Card.you_card?/1" do
    test "true only for the user's own card" do
      base = [
        id: 1,
        status: :idle,
        task: "t",
        display_task: "t",
        created_at: DateTime.from_unix!(0)
      ]

      assert Card.you_card?(struct!(Card, [kind: :you] ++ base))
      refute Card.you_card?(struct!(Card, [kind: :agent] ++ base))
    end
  end
end
