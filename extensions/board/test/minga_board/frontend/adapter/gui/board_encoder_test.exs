defmodule MingaBoard.Frontend.Adapter.GUI.BoardEncoderTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias MingaBoard.Frontend.Adapter.GUI.BoardEncoder
  alias MingaBoard.RenderModel.UI.Board

  @op_gui_extension_runtime Minga.Protocol.Opcodes.gui_extension_runtime()
  @op_gui_board 0x87

  defp encode(%Board{} = board), do: BoardEncoder.encode(board)

  defp unwrap_runtime(binary) do
    <<@op_gui_extension_runtime, envelope_len::32, envelope::binary-size(envelope_len)>> = binary

    <<extension_len::16, extension_id::binary-size(extension_len), channel_len::16,
      channel::binary-size(channel_len), payload::binary>> = envelope

    assert extension_id == "minga_board"
    assert channel == "board"
    payload
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

  describe "encode/1" do
    test "encodes empty board with the legacy extension-owned Board opcode" do
      binary = encode(board())
      payload = unwrap_runtime(binary)

      assert <<@op_gui_board, visible::8, _focused::32, card_count::16, filter_mode::8,
               filter_len::16, _rest::binary>> = payload

      assert visible == 1
      assert card_count == 0
      assert filter_mode == 0
      assert filter_len == 0
    end

    test "encodes a focused card" do
      binary =
        encode(
          board(
            focused_card_id: 1,
            cards: [card(task: "refactor auth", display_task: "refactor auth", model: "claude-4")]
          )
        )

      <<@op_gui_board, _visible::8, focused_id::32, card_count::16, _filter_mode::8,
        filter_len::16, _filter::binary-size(filter_len), rest::binary>> = unwrap_runtime(binary)

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

    test "encodes status, kind, filter, recent files, and sparkline" do
      payload =
        board(
          filter_mode?: true,
          filter_text: "agent",
          cards: [
            card(
              status: :needs_you,
              kind: :you,
              recent_files: ["lib/a.ex"],
              sparkline: [0.0, 0.5, 1.0]
            )
          ]
        )

      %{visible: visible, filter_mode: filter_mode, card_count: card_count, card_data: data} =
        payload |> encode() |> unwrap_runtime() |> parse_board_header()

      assert visible == 1
      assert filter_mode == 1
      assert card_count == 1
      <<_id::32, status::8, flags::8, _rest::binary>> = data
      assert status == 3
      assert (flags &&& 0x01) == 1
    end

    test "encodes zoomed_card_id as a u32 trailer after the cards array" do
      # Zoomed state: visible? is false (grid hidden) but the zoom header data
      # rides along so frontends can render the card identity + ESC affordance.
      binary =
        encode(
          board(
            visible?: false,
            zoomed_card_id: 7,
            cards: [card(id: 7, status: :working, display_task: "fix auth", model: "claude-4")]
          )
        )

      <<@op_gui_board, visible::8, _focused::32, card_count::16, _filter_mode::8, filter_len::16,
        _filter::binary-size(filter_len), rest::binary>> = unwrap_runtime(binary)

      assert visible == 0
      assert card_count == 1

      # Consume the single card, then the trailing zoomed_card_id u32.
      <<_id::32, _status::8, _flags::8, task_len::16, _task::binary-size(task_len), model_len::8,
        _model::binary-size(model_len), _elapsed::32, file_count::8, after_files::binary>> = rest

      assert file_count == 0
      <<sparkline_count::8, _sparkline::binary-size(sparkline_count * 2), zoomed_id::32>> = after_files
      assert zoomed_id == 7
    end

    test "encodes zoomed_card_id of 0 when not zoomed" do
      <<@op_gui_board, _visible::8, _focused::32, card_count::16, _filter_mode::8, filter_len::16,
        _filter::binary-size(filter_len), trailer::binary>> =
        board() |> encode() |> unwrap_runtime()

      assert card_count == 0
      assert <<zoomed_id::32>> = trailer
      assert zoomed_id == 0
    end

    test "rejects malformed cards" do
      invalid_cards = [
        card(id: 0),
        card(status: :mystery),
        card(kind: :robot),
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
  end
end
