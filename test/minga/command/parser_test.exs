defmodule Minga.Command.ParserTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Command.Parser

  describe "parse/1 — write commands" do
    test ":w parses to {:save, []}" do
      assert {:save, []} = Parser.parse("w")
    end

    test "leading/trailing whitespace is trimmed" do
      assert {:save, []} = Parser.parse("  w  ")
    end
  end

  describe "parse/1 — quit commands" do
    test ":q parses to {:quit, []}" do
      assert {:quit, []} = Parser.parse("q")
    end

    test ":q! parses to {:force_quit, []}" do
      assert {:force_quit, []} = Parser.parse("q!")
    end

    test ":wq parses to {:save_quit, []}" do
      assert {:save_quit, []} = Parser.parse("wq")
    end
  end

  describe "parse/1 — edit command" do
    test ":e filename parses to {:edit, filename}" do
      assert {:edit, "README.md"} = Parser.parse("e README.md")
    end

    test ":e with path containing spaces (first word is filename)" do
      assert {:edit, "my file.txt"} = Parser.parse("e my file.txt")
    end

    test ":e with no filename falls back to :unknown" do
      assert {:unknown, "e"} = Parser.parse("e")
    end
  end

  describe "parse/1 — goto line" do
    test ":42 parses to {:goto_line, 42}" do
      assert {:goto_line, 42} = Parser.parse("42")
    end

    test ":1 parses to {:goto_line, 1}" do
      assert {:goto_line, 1} = Parser.parse("1")
    end

    test ":999 parses to {:goto_line, 999}" do
      assert {:goto_line, 999} = Parser.parse("999")
    end

    test "zero is treated as unknown (lines are 1-indexed)" do
      assert {:unknown, "0"} = Parser.parse("0")
    end

    test "negative number is treated as unknown" do
      assert {:unknown, _} = Parser.parse("-5")
    end
  end

  describe "parse/1 — set commands" do
    test ":set number" do
      assert {:set, :number} = Parser.parse("set number")
      assert {:set, :number} = Parser.parse("set nu")
    end

    test ":set nonumber" do
      assert {:set, :nonumber} = Parser.parse("set nonumber")
      assert {:set, :nonumber} = Parser.parse("set nonu")
    end

    test ":set relativenumber" do
      assert {:set, :relativenumber} = Parser.parse("set relativenumber")
      assert {:set, :relativenumber} = Parser.parse("set rnu")
    end

    test ":set norelativenumber" do
      assert {:set, :norelativenumber} = Parser.parse("set norelativenumber")
      assert {:set, :norelativenumber} = Parser.parse("set nornu")
    end
  end

  describe "parse/1 — unknown commands" do
    test "unrecognised command returns {:unknown, raw}" do
      assert {:unknown, "xyz"} = Parser.parse("xyz")
    end

    test "empty string returns {:unknown, \"\"}" do
      assert {:unknown, ""} = Parser.parse("")
    end

    test "partial command returns {:unknown, raw}" do
      assert {:unknown, "wo"} = Parser.parse("wo")
    end
  end
end
