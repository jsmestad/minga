defmodule MingaEditor.Frontend.Protocol.GUIBoardTest do
  @moduledoc """
  Protocol encoding tests for the gui_board opcode (0x87).

  Verifies the wire format for the central typed Board payload, including card fields, status encoding, and UTF-8 text handling.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias MingaEditor.Frontend.Protocol.GUI
  alias MingaEditor.Frontend.Protocol.GUI.BoardCardPayload
  alias MingaEditor.Frontend.Protocol.GUI.BoardPayload

  defp board(attrs \\ []) do
    struct!(
      BoardPayload,
      Keyword.merge([visible?: true, focused_card_id: nil, zoomed_card_id: nil, cards: []], attrs)
    )
  end

  defp card(attrs) do
    struct!(
      BoardCardPayload,
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
    <<0x87, visible::8, focused_id::32, card_count::16, filter_mode::8, filter_len::16,
      _filter::binary-size(filter_len), card_data::binary>> = binary

    %{
      visible: visible,
      focused_id: focused_id,
      card_count: card_count,
      filter_mode: filter_mode,
      card_data: card_data
    }
  end

  describe "encode_gui_board/1" do
    test "encodes empty board with correct opcode and header" do
      binary = GUI.encode_gui_board(board())

      assert <<0x87, visible::8, _focused::32, card_count::16, filter_mode::8, filter_len::16,
               _rest::binary>> = binary

      assert visible == 1
      assert card_count == 0
      assert filter_mode == 0
      assert filter_len == 0
    end

    test "encodes board with one card" do
      binary =
        GUI.encode_gui_board(
          board(
            focused_card_id: 1,
            cards: [card(task: "refactor auth", display_task: "refactor auth", model: "claude-4")]
          )
        )

      <<0x87, _visible::8, focused_id::32, card_count::16, _filter_mode::8, filter_len::16,
        _filter::binary-size(filter_len), rest::binary>> = binary

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
      %{card_count: count} = GUI.encode_gui_board(payload) |> parse_board_header()
      assert count == 3
    end

    test "encodes status bytes correctly" do
      payload = board(cards: [card(status: :working)])
      %{card_data: data} = GUI.encode_gui_board(payload) |> parse_board_header()
      <<_card_id::32, status::8, _::binary>> = data
      assert status == 1
    end

    test "encodes you-card flag for kind: :you card" do
      payload = board(cards: [card(kind: :you)])
      %{card_data: data} = GUI.encode_gui_board(payload) |> parse_board_header()
      <<_card_id::32, _status::8, flags::8, _::binary>> = data
      assert (flags &&& 0x01) == 1
    end

    test "does not set you-card flag for agent card" do
      payload = board(cards: [card(kind: :agent)])
      %{card_data: data} = GUI.encode_gui_board(payload) |> parse_board_header()
      <<_card_id::32, _status::8, flags::8, _::binary>> = data
      assert (flags &&& 0x01) == 0
    end

    test "rejects unknown status values" do
      payload = board(cards: [card(status: :mystery)])

      assert_raise ArgumentError, ~r/invalid Board card payload/, fn ->
        GUI.encode_gui_board(payload)
      end
    end

    test "rejects unknown card kinds" do
      payload = board(cards: [card(kind: :robot)])

      assert_raise ArgumentError, ~r/invalid Board card payload/, fn ->
        GUI.encode_gui_board(payload)
      end
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
        assert_raise ArgumentError, ~r/invalid Board card payload/, fn ->
          GUI.encode_gui_board(board(cards: [invalid_card]))
        end
      end)
    end

    test "encodes focused card flag" do
      payload = board(focused_card_id: 1, cards: [card(id: 1), card(id: 2)])
      %{card_data: data} = GUI.encode_gui_board(payload) |> parse_board_header()
      <<_c1_id::32, _s1::8, flags1::8, _rest::binary>> = data
      assert (flags1 &&& 0x02) != 0
    end

    test "encodes UTF-8 task and model strings" do
      payload = board(cards: [card(task: "修复认证 🔐", display_task: "修复认证 🔐", model: "gemini-2")])
      %{card_data: data} = GUI.encode_gui_board(payload) |> parse_board_header()

      <<_id::32, _s::8, _f::8, task_len::16, task::binary-size(task_len), model_len::8,
        model::binary-size(model_len), _::binary>> = data

      assert task == "修复认证 🔐"
      assert model == "gemini-2"
    end

    test "encodes recent files" do
      payload = board(cards: [card(recent_files: ["lib/auth.ex", "test/auth_test.exs"])])
      %{card_data: data} = GUI.encode_gui_board(payload) |> parse_board_header()

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
      %{visible: visible} = GUI.encode_gui_board(payload) |> parse_board_header()
      assert visible == 0
    end

    test "encodes filter mode and text" do
      payload = board(filter_mode?: true, filter_text: "auth")
      %{filter_mode: fm} = GUI.encode_gui_board(payload) |> parse_board_header()
      assert fm == 1
    end

    test "encodes sparkline data as Float16" do
      payload = board(cards: [card(sparkline: [0.0, 0.5, 1.0])])
      %{card_data: data} = GUI.encode_gui_board(payload) |> parse_board_header()

      <<_id::32, _s::8, _f::8, task_len::16, _task::binary-size(task_len), model_len::8,
        _model::binary-size(model_len), _elapsed::32, _file_count::8, sparkline_count::8, s1::16,
        s2::16, s3::16>> = data

      assert sparkline_count == 3
      assert s1 == 0
      assert s2 == 32_768
      assert s3 == 65_535
    end
  end
end
