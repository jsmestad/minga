defmodule Minga.TerminalTest do
  use ExUnit.Case, async: true

  alias Minga.Terminal

  describe "new/0" do
    test "creates terminal with user shell" do
      term = Terminal.new()
      assert is_binary(term.shell)
      refute term.open
      refute term.focused
    end
  end

  describe "open/6" do
    test "marks terminal as open with dimensions" do
      term = Terminal.new() |> Terminal.open(24, 80, 10, 0, 5)
      assert term.open
      assert term.focused
      assert term.rows == 24
      assert term.cols == 80
      assert term.row_offset == 10
      assert term.col_offset == 0
      assert term.window_id == 5
    end
  end

  describe "close/1" do
    test "marks terminal as closed and clears window id" do
      term = Terminal.new() |> Terminal.open(24, 80, 10, 0, 5) |> Terminal.close()
      refute term.open
      refute term.focused
      assert term.window_id == nil
    end
  end

  describe "set_focus/2" do
    test "toggles focus state" do
      term = Terminal.new() |> Terminal.open(24, 80, 10, 0, 5)
      assert term.focused

      term = Terminal.set_focus(term, false)
      refute term.focused

      term = Terminal.set_focus(term, true)
      assert term.focused
    end
  end

  describe "resize/5" do
    test "updates dimensions" do
      term = Terminal.new() |> Terminal.open(24, 80, 10, 0, 5) |> Terminal.resize(30, 100, 15, 5)
      assert term.rows == 30
      assert term.cols == 100
      assert term.row_offset == 15
      assert term.col_offset == 5
    end
  end
end
