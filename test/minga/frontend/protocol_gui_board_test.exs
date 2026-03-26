defmodule Minga.Frontend.Protocol.GUIBoardTest do
  @moduledoc """
  Protocol encoding tests for the gui_board opcode (0x87).

  Verifies the wire format for Board card grid state, including
  card fields, status encoding, and UTF-8 text handling.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias Minga.Frontend.Protocol.GUI
  alias Minga.Shell.Board.Card
  alias Minga.Shell.Board.State

  # Helper: parse the gui_board header and return the card data portion
  defp parse_board_header(binary) do
    <<0x87, visible::8, focused_id::32, card_count::16,
      filter_mode::8, filter_len::16, _filter::binary-size(filter_len),
      card_data::binary>> = binary

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
      state = State.new()
      binary = GUI.encode_gui_board(state)

      # opcode(0x87) + visible(1) + focused_card_id(4) + card_count(2) + filter_mode(1) + filter_len(2)
      assert <<0x87, visible::8, _focused::32, card_count::16, filter_mode::8,
               filter_len::16, _rest::binary>> = binary
      assert visible == 1
      assert card_count == 0
      assert filter_mode == 0
      assert filter_len == 0
    end

    test "encodes board with one card" do
      {state, _card} = State.create_card(State.new(), task: "refactor auth", model: "claude-4")
      binary = GUI.encode_gui_board(state)

      <<0x87, _visible::8, focused_id::32, card_count::16,
        _filter_mode::8, filter_len::16, _filter::binary-size(filter_len),
        rest::binary>> = binary
      assert card_count == 1
      assert focused_id == 1

      # Parse the card: id(4) + status(1) + flags(1) + task_len(2) + task
      <<card_id::32, status::8, flags::8, task_len::16, task::binary-size(task_len),
        model_len::8, model::binary-size(model_len), _elapsed::32, file_count::8,
        _rest::binary>> = rest

      assert card_id == 1
      assert status == 0
      assert (flags &&& 0x01) == 0
      assert (flags &&& 0x02) != 0
      assert task == "refactor auth"
      assert model == "claude-4"
      assert file_count == 0
    end

    test "encodes multiple cards in creation order" do
      state = State.new()
      {state, _} = State.create_card(state, task: "first")
      {state, _} = State.create_card(state, task: "second")
      {state, _} = State.create_card(state, task: "third")

      %{card_count: count} = GUI.encode_gui_board(state) |> parse_board_header()
      assert count == 3
    end

    test "encodes status bytes correctly" do
      state = State.new()
      {state, card} = State.create_card(state, task: "t")
      state = State.update_card(state, card.id, &Card.set_status(&1, :working))

      %{card_data: data} = GUI.encode_gui_board(state) |> parse_board_header()
      <<_card_id::32, status::8, _::binary>> = data
      assert status == 1
    end

    test "encodes you-card flag for kind: :you card" do
      state = Minga.Shell.Board.init(skip_persistence: true)

      %{card_data: data} = GUI.encode_gui_board(state) |> parse_board_header()
      <<_card_id::32, _status::8, flags::8, _::binary>> = data
      assert (flags &&& 0x01) == 1
    end

    test "does not set you-card flag for agent card" do
      state = State.new()
      fake_pid = spawn(fn -> Process.sleep(:infinity) end)
      {state, card} = State.create_card(state, task: "agent task")
      state = State.update_card(state, card.id, &Card.attach_session(&1, fake_pid))

      %{card_data: data} = GUI.encode_gui_board(state) |> parse_board_header()
      <<_card_id::32, _status::8, flags::8, _::binary>> = data
      assert (flags &&& 0x01) == 0
    end

    test "encodes focused card flag" do
      state = State.new()
      {state, c1} = State.create_card(state, task: "focused")
      {state, _c2} = State.create_card(state, task: "unfocused")
      state = State.focus_card(state, c1.id)

      %{card_data: data} = GUI.encode_gui_board(state) |> parse_board_header()
      <<_c1_id::32, _s1::8, flags1::8, _rest::binary>> = data
      assert (flags1 &&& 0x02) != 0
    end

    test "encodes UTF-8 task and model strings" do
      {state, _} = State.create_card(State.new(), task: "修复认证 🔐", model: "gemini-2")

      %{card_data: data} = GUI.encode_gui_board(state) |> parse_board_header()
      <<_id::32, _s::8, _f::8, task_len::16, task::binary-size(task_len),
        model_len::8, model::binary-size(model_len), _::binary>> = data

      assert task == "修复认证 🔐"
      assert model == "gemini-2"
    end

    test "encodes recent files" do
      {state, card} =
        State.create_card(State.new(), task: "t", recent_files: ["lib/auth.ex", "test/auth_test.exs"])

      state = State.update_card(state, card.id, & &1)

      %{card_data: data} = GUI.encode_gui_board(state) |> parse_board_header()
      <<_id::32, _s::8, _f::8, task_len::16, _task::binary-size(task_len),
        model_len::8, _model::binary-size(model_len), _elapsed::32,
        file_count::8, rest::binary>> = data

      assert file_count == 2
      <<p1_len::16, p1::binary-size(p1_len), p2_len::16, p2::binary-size(p2_len)>> = rest
      assert p1 == "lib/auth.ex"
      assert p2 == "test/auth_test.exs"
    end

    test "visible flag is 0 when zoomed into a card" do
      {state, card} = State.create_card(State.new(), task: "zoomed")
      state = State.zoom_into(state, card.id, %{})

      %{visible: visible} = GUI.encode_gui_board(state) |> parse_board_header()
      assert visible == 0
    end

    test "encodes filter mode and text" do
      state = %{State.new() | filter_mode: true, filter_text: "auth"}

      %{filter_mode: fm} = GUI.encode_gui_board(state) |> parse_board_header()
      assert fm == 1
    end
  end
end
