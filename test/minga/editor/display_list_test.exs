defmodule Minga.Editor.DisplayListTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame, Overlay, WindowFrame}
  alias Minga.Port.Protocol

  describe "draw/4" do
    test "creates a draw tuple with default empty style" do
      assert DisplayList.draw(0, 5, "hello") == {0, 5, "hello", []}
    end

    test "creates a draw tuple with style" do
      d = DisplayList.draw(1, 10, "world", fg: 0xFF0000, bold: true)
      assert d == {1, 10, "world", [fg: 0xFF0000, bold: true]}
    end
  end

  describe "draws_to_layer/1" do
    test "groups draws by row" do
      draws = [
        {0, 0, "a", []},
        {0, 5, "b", [fg: 0xFF0000]},
        {1, 0, "c", []}
      ]

      layer = DisplayList.draws_to_layer(draws)

      assert Map.has_key?(layer, 0)
      assert Map.has_key?(layer, 1)
      assert length(layer[0]) == 2
      assert length(layer[1]) == 1
    end

    test "strips row from tuples to produce text_runs" do
      draws = [{3, 7, "hello", [fg: 0xFF]}]
      layer = DisplayList.draws_to_layer(draws)

      assert layer[3] == [{7, "hello", [fg: 0xFF]}]
    end

    test "empty list produces empty map" do
      assert DisplayList.draws_to_layer([]) == %{}
    end
  end

  describe "offset_draws/3" do
    test "offsets row and col" do
      draws = [{0, 0, "a", []}, {1, 5, "b", []}]
      result = DisplayList.offset_draws(draws, 10, 20)

      assert result == [{10, 20, "a", []}, {11, 25, "b", []}]
    end

    test "zero offset is identity" do
      draws = [{3, 7, "x", [fg: 1]}]
      assert DisplayList.offset_draws(draws, 0, 0) == draws
    end
  end

  describe "grayscale_draws/1" do
    test "converts colors to grayscale" do
      draws = [{0, 0, "hi", [fg: 0xFF0000, bg: 0x00FF00]}]
      [result] = DisplayList.grayscale_draws(draws)
      {0, 0, "hi", style} = result
      fg = Keyword.get(style, :fg)
      bg = Keyword.get(style, :bg)
      # Grayscale red (0xFF0000): 0.299 * 255 ≈ 76 → 0x4C4C4C
      assert fg != 0xFF0000
      assert bg != 0x00FF00
      # Verify it's actually gray (r == g == b)
      fg_r = Bitwise.band(Bitwise.bsr(fg, 16), 0xFF)
      fg_g = Bitwise.band(Bitwise.bsr(fg, 8), 0xFF)
      fg_b = Bitwise.band(fg, 0xFF)
      assert fg_r == fg_g
      assert fg_g == fg_b
    end
  end

  describe "layer_to_draws/1" do
    test "flattens a render layer back to draws" do
      layer = %{
        0 => [{5, "hello", [fg: 0xFF]}],
        2 => [{0, "world", []}]
      }

      draws = DisplayList.layer_to_draws(layer)
      assert length(draws) == 2

      assert Enum.member?(draws, {0, 5, "hello", [fg: 0xFF]})
      assert Enum.member?(draws, {2, 0, "world", []})
    end
  end

  describe "changed_rows/2" do
    test "detects added rows" do
      old = %{}
      new = %{0 => [{0, "hello", []}]}
      assert MapSet.member?(DisplayList.changed_rows(old, new), 0)
    end

    test "detects removed rows" do
      old = %{0 => [{0, "hello", []}]}
      new = %{}
      assert MapSet.member?(DisplayList.changed_rows(old, new), 0)
    end

    test "detects modified rows" do
      old = %{0 => [{0, "hello", []}]}
      new = %{0 => [{0, "world", []}]}
      assert MapSet.member?(DisplayList.changed_rows(old, new), 0)
    end

    test "ignores unchanged rows" do
      layer = %{0 => [{0, "hello", []}], 1 => [{0, "world", []}]}
      assert DisplayList.changed_rows(layer, layer) == MapSet.new()
    end
  end

  describe "to_commands/1" do
    test "produces clear, cursor_shape, cursor, and batch_end" do
      frame = %Frame{cursor: Cursor.new(5, 10, :beam)}
      commands = DisplayList.to_commands(frame)

      assert hd(commands) == Protocol.encode_clear()
      assert List.last(commands) == Protocol.encode_batch_end()

      assert Enum.member?(commands, Protocol.encode_cursor(5, 10))
      assert Enum.member?(commands, Protocol.encode_cursor_shape(:beam))
    end

    test "encodes window frame draws at rect offset" do
      wf = %WindowFrame{
        rect: {10, 20, 40, 5},
        lines: %{0 => [{0, "hello", [fg: 0xFF0000]}]}
      }

      frame = %Frame{cursor: Cursor.new(0, 0, :block), windows: [wf]}
      commands = DisplayList.to_commands(frame)

      # The draw should be at row 10+0=10, col 20+0=20
      expected = Protocol.encode_draw(10, 20, "hello", fg: 0xFF0000)
      assert Enum.member?(commands, expected)
    end

    test "encodes splash draws directly" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [{0, 0, "Welcome", []}]
      }

      commands = DisplayList.to_commands(frame)
      expected = Protocol.encode_draw(0, 0, "Welcome")
      assert Enum.member?(commands, expected)
    end

    test "encodes overlay draws" do
      overlay = %Overlay{draws: [{5, 0, "popup", [fg: 0xFFFF00]}]}

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        overlays: [overlay]
      }

      commands = DisplayList.to_commands(frame)
      expected = Protocol.encode_draw(5, 0, "popup", fg: 0xFFFF00)
      assert Enum.member?(commands, expected)
    end

    test "includes region commands pass-through" do
      region_cmd = Protocol.encode_define_region(1, 0, :editor, 0, 0, 80, 24, 0)

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        regions: [region_cmd]
      }

      commands = DisplayList.to_commands(frame)
      assert Enum.member?(commands, region_cmd)
    end

    test "round-trips a known draw to identical protocol binary" do
      # Verify that draw → to_commands produces the same binary as Protocol.encode_draw
      style = [fg: 0xFF6C6B, bg: 0x282C34, bold: true]
      expected_binary = Protocol.encode_draw(5, 10, "hello world", style)

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        minibuffer: [{5, 10, "hello world", style}]
      }

      commands = DisplayList.to_commands(frame)
      assert Enum.member?(commands, expected_binary)
    end
  end

  describe "draws_to_commands/1" do
    test "converts draw tuples to protocol binaries" do
      draws = [
        {0, 0, "hello", []},
        {1, 5, "world", [fg: 0xFF0000]}
      ]

      commands = DisplayList.draws_to_commands(draws)

      assert length(commands) == 2
      assert Enum.all?(commands, &is_binary/1)

      assert Enum.at(commands, 0) == Protocol.encode_draw(0, 0, "hello")
      assert Enum.at(commands, 1) == Protocol.encode_draw(1, 5, "world", fg: 0xFF0000)
    end
  end
end
