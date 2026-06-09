defmodule MingaBoard.RenderModel.UI.BoardBuilderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MingaBoard.RenderModel.UI.Board
  alias MingaBoard.RenderModel.UI.BoardBuilder

  describe "build/1" do
    test "builds a hidden board when payload is nil" do
      assert %Board{visible?: false, cards: []} = BoardBuilder.build(nil)
    end

    test "builds a hidden board when payload is unsupported" do
      {model, log} = with_log(fn -> BoardBuilder.build({:unknown, %{}}) end)

      assert %Board{visible?: false, cards: []} = model
      assert log =~ "Unsupported Board extension GUI payload"
    end

    test "passes a board payload through as the render model" do
      board = %Board{
        visible?: true,
        focused_card_id: 1,
        cards: [
          %Board.Card{
            id: 1,
            status: :idle,
            kind: :agent,
            task: "Test task",
            display_task: "Test task",
            created_at: DateTime.from_unix!(0)
          }
        ]
      }

      assert BoardBuilder.build({:board, board}) == board
    end
  end
end
