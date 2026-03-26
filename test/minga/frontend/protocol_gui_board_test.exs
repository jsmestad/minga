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

  describe "encode_gui_board/1" do
    test "encodes empty board with correct opcode and header" do
      state = State.new()
      binary = GUI.encode_gui_board(state)

      # opcode(0x87) + visible(1) + focused_card_id(4) + card_count(2)
      assert <<0x87, visible::8, _focused::32, card_count::16>> = binary
      assert visible == 1
      assert card_count == 0
    end

    test "encodes board with one card" do
      {state, _card} = State.create_card(State.new(), task: "refactor auth", model: "claude-4")
      binary = GUI.encode_gui_board(state)

      <<0x87, _visible::8, focused_id::32, card_count::16, rest::binary>> = binary
      assert card_count == 1
      assert focused_id == 1

      # Parse the card: id(4) + status(1) + flags(1) + task_len(2) + task
      <<card_id::32, status::8, flags::8, task_len::16, task::binary-size(task_len),
        model_len::8, model::binary-size(model_len), _elapsed::32, file_count::8,
        _rest::binary>> = rest

      assert card_id == 1
      assert status == 0
      # is_you_card (session: nil)
      assert (flags &&& 0x01) == 1
      # is_focused
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

      binary = GUI.encode_gui_board(state)
      <<0x87, _::8, _::32, card_count::16, _::binary>> = binary
      assert card_count == 3
    end

    test "encodes status bytes correctly" do
      state = State.new()
      {state, card} = State.create_card(state, task: "t")
      state = State.update_card(state, card.id, &Card.set_status(&1, :working))

      binary = GUI.encode_gui_board(state)
      <<0x87, _::8, _::32, 1::16, _card_id::32, status::8, _::binary>> = binary
      assert status == 1
    end

    test "encodes you-card flag for session-less card" do
      # Board.init creates a "You" card with session: nil
      state = Minga.Shell.Board.init()
      binary = GUI.encode_gui_board(state)

      <<0x87, _::8, _::32, 1::16, _card_id::32, _status::8, flags::8, _::binary>> = binary
      # is_you_card flag (bit 0) should be set (session: nil)
      assert (flags &&& 0x01) == 1
    end

    test "does not set you-card flag for agent card" do
      state = State.new()
      fake_pid = spawn(fn -> Process.sleep(:infinity) end)
      {state, card} = State.create_card(state, task: "agent task")
      state = State.update_card(state, card.id, &Card.attach_session(&1, fake_pid))

      binary = GUI.encode_gui_board(state)

      <<0x87, _::8, _::32, 1::16, _card_id::32, _status::8, flags::8, _::binary>> = binary
      assert (flags &&& 0x01) == 0
    end

    test "encodes focused card flag" do
      state = State.new()
      {state, c1} = State.create_card(state, task: "focused")
      {state, _c2} = State.create_card(state, task: "unfocused")
      state = State.focus_card(state, c1.id)

      binary = GUI.encode_gui_board(state)

      <<0x87, _::8, _::32, 2::16, _c1_id::32, _s1::8, flags1::8, _rest::binary>> = binary
      # First card should have is_focused flag
      assert (flags1 &&& 0x02) != 0
    end

    test "encodes UTF-8 task and model strings" do
      {state, _} = State.create_card(State.new(), task: "修复认证 🔐", model: "gemini-2")
      binary = GUI.encode_gui_board(state)

      <<0x87, _::8, _::32, 1::16, _id::32, _s::8, _f::8, task_len::16,
        task::binary-size(task_len), model_len::8, model::binary-size(model_len),
        _::binary>> = binary

      assert task == "修复认证 🔐"
      assert model == "gemini-2"
    end

    test "encodes recent files" do
      {state, card} =
        State.create_card(State.new(), task: "t", recent_files: ["lib/auth.ex", "test/auth_test.exs"])

      state = State.update_card(state, card.id, & &1)
      binary = GUI.encode_gui_board(state)

      # Parse past card header to file section
      <<0x87, _::8, _::32, 1::16, _id::32, _s::8, _f::8, task_len::16,
        _task::binary-size(task_len), model_len::8, _model::binary-size(model_len),
        _elapsed::32, file_count::8, rest::binary>> = binary

      assert file_count == 2

      <<path1_len::16, path1::binary-size(path1_len), path2_len::16,
        path2::binary-size(path2_len)>> = rest

      assert path1 == "lib/auth.ex"
      assert path2 == "test/auth_test.exs"
    end

    test "visible flag is 0 when zoomed into a card" do
      {state, card} = State.create_card(State.new(), task: "zoomed")
      state = State.zoom_into(state, card.id, %{})

      binary = GUI.encode_gui_board(state)
      <<0x87, visible::8, _::binary>> = binary
      assert visible == 0
    end
  end
end
