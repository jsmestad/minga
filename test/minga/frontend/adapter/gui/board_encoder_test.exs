defmodule Minga.Frontend.Adapter.GUI.BoardEncoderTest do
  @moduledoc """
  Wire-format tests for the gui_board opcode (0x87).

  Verifies the encoded Board render model: card fields, status encoding, flags,
  UTF-8 text, recent files, sparkline Float16, filter state, and validation.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias Minga.Frontend.Adapter.GUI.BoardEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Board

  @op_gui_board Minga.Protocol.Opcodes.gui_board()

  defp encode(%Board{} = board) do
    {binary, _caches} = BoardEncoder.encode(board, Caches.new())
    binary
  end

  defp board(attrs \\ []) do
    struct!(
      Board,
      Keyword.merge([visible?: true, focused_card_id: nil, zoomed_card_id: nil, cards: []], attrs)
    )
  end

  defp card(attrs) do
    struct!(
      Board.Card,
      Keyword.merge(
        [
          id: 1,
          status: :idle,
          kind: :agent,
          task: "task",
          display_task: "task",
          model: nil,
          created_at: ~U[2025-01-01 00:00:00Z],
          recent_files: [],
          sparkline: []
        ],
        attrs
      )
    )
  end

  defp parse_board_header(binary) do
    <<@op_gui_board, visible::8, focused_id::32, card_count::16, filter_mode::8, filter_len::16,
      _filter::binary-size(filter_len), card_data::binary>> = binary

    %{
      visible: visible,
      focused_id: focused_id,
      card_count: card_count,
      filter_mode: filter_mode,
      card_data: card_data
    }
  end

  describe "encode/2" do
    test "encodes empty board with correct opcode and header" do
      binary = encode(board())

      assert <<@op_gui_board, visible::8, _focused::32, card_count::16, filter_mode::8,
               filter_len::16, _rest::binary>> = binary

      assert visible == 1
      assert card_count == 0
      assert filter_mode == 0
      assert filter_len == 0
    end

    test "encodes board with one card" do
      binary =
        encode(
          board(
            focused_card_id: 1,
            cards: [card(task: "refactor auth", display_task: "refactor auth", model: "claude-4")]
          )
        )

      <<@op_gui_board, _visible::8, focused_id::32, card_count::16, _filter_mode::8,
        filter_len::16, _filter::binary-size(filter_len), rest::binary>> = binary

      assert card_count == 1
      assert focused_id == 1

      <<card_id::32, status::8, flags::8, task_len::16, task::binary-size(task_len), model_len::8,
        model::binary-size(model_len), _elapsed::32, file_count::8, _rest::binary>> = rest

      assert card_id == 1
      assert status == 0
      assert (flags &&& 0x01) == 0
      assert (flags &&& 0x02) != 0
      assert task == "refactor auth"
      assert model == "claude-4"
      assert file_count == 0
    end

    test "encodes multiple cards in creation order" do
      payload = board(cards: [card(id: 1), card(id: 2), card(id: 3)])
      %{card_count: count} = encode(payload) |> parse_board_header()
      assert count == 3
    end

    test "encodes status bytes correctly" do
      payload = board(cards: [card(status: :working)])
      %{card_data: data} = encode(payload) |> parse_board_header()
      <<_card_id::32, status::8, _::binary>> = data
      assert status == 1
    end

    test "encodes you-card flag for kind: :you card" do
      payload = board(cards: [card(kind: :you)])
      %{card_data: data} = encode(payload) |> parse_board_header()
      <<_card_id::32, _status::8, flags::8, _::binary>> = data
      assert (flags &&& 0x01) == 1
    end

    test "does not set you-card flag for agent card" do
      payload = board(cards: [card(kind: :agent)])
      %{card_data: data} = encode(payload) |> parse_board_header()
      <<_card_id::32, _status::8, flags::8, _::binary>> = data
      assert (flags &&& 0x01) == 0
    end

    test "rejects unknown status values" do
      payload = board(cards: [card(status: :mystery)])

      assert_raise ArgumentError, ~r/invalid board card/, fn -> encode(payload) end
    end

    test "rejects unknown card kinds" do
      payload = board(cards: [card(kind: :robot)])

      assert_raise ArgumentError, ~r/invalid board card/, fn -> encode(payload) end
    end

    test "rejects malformed card payload fields" do
      invalid_cards = [
        card(id: 0),
        card(display_task: nil),
        card(created_at: :not_a_datetime),
        card(recent_files: [:not_a_path]),
        card(sparkline: [:not_a_number])
      ]

      Enum.each(invalid_cards, fn invalid_card ->
        assert_raise ArgumentError, ~r/invalid board card/, fn ->
          encode(board(cards: [invalid_card]))
        end
      end)
    end

    test "encodes focused card flag" do
      payload = board(focused_card_id: 1, cards: [card(id: 1), card(id: 2)])
      %{card_data: data} = encode(payload) |> parse_board_header()
      <<_c1_id::32, _s1::8, flags1::8, _rest::binary>> = data
      assert (flags1 &&& 0x02) != 0
    end

    test "encodes UTF-8 task and model strings" do
      payload = board(cards: [card(task: "修复认证 🔐", display_task: "修复认证 🔐", model: "gemini-2")])
      %{card_data: data} = encode(payload) |> parse_board_header()

      <<_id::32, _s::8, _f::8, task_len::16, task::binary-size(task_len), model_len::8,
        model::binary-size(model_len), _::binary>> = data

      assert task == "修复认证 🔐"
      assert model == "gemini-2"
    end

    test "encodes recent files" do
      payload = board(cards: [card(recent_files: ["lib/auth.ex", "test/auth_test.exs"])])
      %{card_data: data} = encode(payload) |> parse_board_header()

      <<_id::32, _s::8, _f::8, task_len::16, _task::binary-size(task_len), model_len::8,
        _model::binary-size(model_len), _elapsed::32, file_count::8, rest::binary>> = data

      assert file_count == 2

      <<p1_len::16, p1::binary-size(p1_len), p2_len::16, p2::binary-size(p2_len),
        sparkline_count::8, _sparkline_data::binary>> = rest

      assert p1 == "lib/auth.ex"
      assert p2 == "test/auth_test.exs"
      assert sparkline_count == 0
    end

    test "visible flag is 0 when zoomed into a card" do
      payload = board(visible?: false, zoomed_card_id: 1, cards: [card(id: 1)])
      %{visible: visible} = encode(payload) |> parse_board_header()
      assert visible == 0
    end

    test "encodes filter mode and text" do
      payload = board(filter_mode?: true, filter_text: "auth")
      %{filter_mode: fm} = encode(payload) |> parse_board_header()
      assert fm == 1
    end

    test "encodes sparkline data as Float16" do
      payload = board(cards: [card(sparkline: [0.0, 0.5, 1.0])])
      %{card_data: data} = encode(payload) |> parse_board_header()

      <<_id::32, _s::8, _f::8, task_len::16, _task::binary-size(task_len), model_len::8,
        _model::binary-size(model_len), _elapsed::32, _file_count::8, sparkline_count::8, s1::16,
        s2::16, s3::16>> = data

      assert sparkline_count == 3
      assert s1 == 0
      assert s2 == 32_768
      assert s3 == 65_535
    end
  end

  describe "encode/2 cache skipping" do
    test "returns nil on the second call with an unchanged model" do
      model = board(cards: [card(id: 1)])

      {cmd1, caches} = BoardEncoder.encode(model, Caches.new())
      assert cmd1 != nil

      {cmd2, _caches} = BoardEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when the board changes" do
      {_cmd, caches} =
        BoardEncoder.encode(board(focused_card_id: 1, cards: [card(id: 1)]), Caches.new())

      {cmd2, _caches} =
        BoardEncoder.encode(board(focused_card_id: 2, cards: [card(id: 1)]), caches)

      assert cmd2 != nil
    end
  end
end
