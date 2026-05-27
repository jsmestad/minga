defmodule MingaEditor.RenderModel.UI.BoardBuilderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MingaEditor.RenderModel.UI.BoardBuilder
  alias Minga.RenderModel.UI.Board
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Frontend.Protocol.GUI.BoardPayload
  alias MingaEditor.Frontend.Protocol.GUI.BoardCardPayload

  @op_gui_board Minga.Protocol.Opcodes.gui_board()

  describe "build/1" do
    test "builds dismissed board when payload is nil" do
      model = BoardBuilder.build(nil)

      assert %Board{fingerprint: :dismissed} = model
      assert is_binary(model.encoded)
      assert <<@op_gui_board, 0::8, _rest::binary>> = model.encoded
    end

    test "builds dismissed board when payload is unsupported (with warning)" do
      {model, log} =
        with_log(fn ->
          BoardBuilder.build({:unknown, %{}})
        end)

      assert %Board{fingerprint: :dismissed} = model
      assert log =~ "Unsupported GUI shell payload"
    end

    test "builds active board from board payload" do
      board = %BoardPayload{
        visible?: true,
        focused_card_id: 1,
        cards: [
          %BoardCardPayload{
            id: 1,
            status: :idle,
            kind: :agent,
            task: "Test task",
            display_task: "Test task",
            created_at: DateTime.from_unix!(0)
          }
        ]
      }

      model = BoardBuilder.build({:board, board})

      assert %Board{} = model
      assert is_integer(model.fingerprint)
      assert is_binary(model.encoded)
      assert <<@op_gui_board, 1::8, _rest::binary>> = model.encoded
    end

    test "produces byte-identical output to legacy for dismissed board" do
      legacy_binary = ProtocolGUI.encode_gui_board(BoardPayload.hidden())

      model = BoardBuilder.build(nil)

      assert model.encoded == legacy_binary,
             "Dismissed board: new builder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for active board" do
      board = %BoardPayload{
        visible?: true,
        focused_card_id: 42,
        zoomed_card_id: nil,
        filter_mode?: false,
        filter_text: "",
        cards: [
          %BoardCardPayload{
            id: 42,
            status: :working,
            kind: :agent,
            task: "Fix the build",
            display_task: "Fix the build",
            model: "claude-3-opus",
            created_at: ~U[2024-01-15 10:30:00Z],
            recent_files: ["lib/app.ex", "test/app_test.exs"],
            sparkline: [0.1, 0.5, 0.8, 1.0, 0.3]
          },
          %BoardCardPayload{
            id: 1,
            status: :idle,
            kind: :you,
            task: "My workspace",
            display_task: "My workspace",
            created_at: ~U[2024-01-15 08:00:00Z]
          }
        ]
      }

      legacy_binary = ProtocolGUI.encode_gui_board(board)

      model = BoardBuilder.build({:board, board})

      assert model.encoded == legacy_binary,
             "Active board with cards: new builder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for board with filter" do
      board = %BoardPayload{
        visible?: true,
        focused_card_id: 1,
        zoomed_card_id: nil,
        filter_mode?: true,
        filter_text: "search term",
        cards: [
          %BoardCardPayload{
            id: 1,
            status: :done,
            kind: :agent,
            task: "Done task",
            display_task: "Done task",
            created_at: DateTime.from_unix!(0)
          }
        ]
      }

      legacy_binary = ProtocolGUI.encode_gui_board(board)

      model = BoardBuilder.build({:board, board})

      assert model.encoded == legacy_binary,
             "Board with filter: new builder output does not match legacy output"
    end

    test "fingerprint changes when board content changes" do
      card = %BoardCardPayload{
        id: 1,
        status: :idle,
        kind: :agent,
        task: "Task",
        display_task: "Task",
        created_at: DateTime.from_unix!(0)
      }

      board1 = %BoardPayload{visible?: true, focused_card_id: 1, cards: [card]}
      board2 = %BoardPayload{visible?: true, focused_card_id: 2, cards: [card]}

      model1 = BoardBuilder.build({:board, board1})
      model2 = BoardBuilder.build({:board, board2})

      assert model1.fingerprint != model2.fingerprint
    end
  end
end
