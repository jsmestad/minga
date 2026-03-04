defmodule Minga.Keymap.KeyParserTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.KeyParser

  doctest KeyParser

  describe "parse/1" do
    test "parses single character" do
      assert {:ok, [{?a, 0}]} = KeyParser.parse("a")
    end

    test "parses uppercase character" do
      assert {:ok, [{?A, 0}]} = KeyParser.parse("A")
    end

    test "parses SPC" do
      assert {:ok, [{32, 0}]} = KeyParser.parse("SPC")
    end

    test "parses TAB" do
      assert {:ok, [{9, 0}]} = KeyParser.parse("TAB")
    end

    test "parses RET" do
      assert {:ok, [{13, 0}]} = KeyParser.parse("RET")
    end

    test "parses ESC" do
      assert {:ok, [{27, 0}]} = KeyParser.parse("ESC")
    end

    test "parses DEL" do
      assert {:ok, [{127, 0}]} = KeyParser.parse("DEL")
    end

    test "parses Ctrl modifier" do
      assert {:ok, [{?s, 0x02}]} = KeyParser.parse("C-s")
    end

    test "parses Alt/Meta modifier" do
      assert {:ok, [{?x, 0x04}]} = KeyParser.parse("M-x")
    end

    test "parses multi-key leader sequence" do
      assert {:ok, [{32, 0}, {?g, 0}, {?s, 0}]} = KeyParser.parse("SPC g s")
    end

    test "parses SPC f f" do
      assert {:ok, [{32, 0}, {?f, 0}, {?f, 0}]} = KeyParser.parse("SPC f f")
    end

    test "parses two-key sequence" do
      assert {:ok, [{?g, 0}, {?g, 0}]} = KeyParser.parse("g g")
    end

    test "parses mixed modifiers" do
      assert {:ok, [{?x, 0x02}, {?s, 0x02}]} = KeyParser.parse("C-x C-s")
    end

    test "handles leading and trailing whitespace" do
      assert {:ok, [{?a, 0}]} = KeyParser.parse("  a  ")
    end

    test "returns error for empty string" do
      assert {:error, "empty key sequence"} = KeyParser.parse("")
    end

    test "returns error for whitespace-only string" do
      assert {:error, "empty key sequence"} = KeyParser.parse("   ")
    end

    test "returns error for unrecognized token" do
      assert {:error, msg} = KeyParser.parse("INVALID")
      assert msg =~ "unrecognized"
    end
  end

  describe "parse!/1" do
    test "returns keys for valid input" do
      assert [{32, 0}, {?f, 0}] = KeyParser.parse!("SPC f")
    end

    test "raises for invalid input" do
      assert_raise ArgumentError, ~r/invalid key sequence/, fn ->
        KeyParser.parse!("")
      end
    end
  end
end
