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

    test ":wqa parses to {:save_quit_all, []}" do
      assert {:save_quit_all, []} = Parser.parse("wqa")
    end

    test ":wqall parses to {:save_quit_all, []}" do
      assert {:save_quit_all, []} = Parser.parse("wqall")
    end

    test ":qa parses to {:quit_all, []}" do
      assert {:quit_all, []} = Parser.parse("qa")
    end

    test ":qa! parses to {:force_quit_all, []}" do
      assert {:force_quit_all, []} = Parser.parse("qa!")
    end

    test ":qall parses to {:quit_all, []}" do
      assert {:quit_all, []} = Parser.parse("qall")
    end

    test ":qall! parses to {:force_quit_all, []}" do
      assert {:force_quit_all, []} = Parser.parse("qall!")
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

  describe "parse/1 — setglobal commands" do
    test ":setglobal number" do
      assert {:setglobal, :number} = Parser.parse("setglobal number")
      assert {:setglobal, :number} = Parser.parse("setglobal nu")
    end

    test ":setglobal nonumber" do
      assert {:setglobal, :nonumber} = Parser.parse("setglobal nonumber")
      assert {:setglobal, :nonumber} = Parser.parse("setglobal nonu")
    end

    test ":setglobal relativenumber" do
      assert {:setglobal, :relativenumber} = Parser.parse("setglobal relativenumber")
      assert {:setglobal, :relativenumber} = Parser.parse("setglobal rnu")
    end

    test ":setglobal norelativenumber" do
      assert {:setglobal, :norelativenumber} = Parser.parse("setglobal norelativenumber")
      assert {:setglobal, :norelativenumber} = Parser.parse("setglobal nornu")
    end

    test ":setglobal wrap" do
      assert {:setglobal, :wrap} = Parser.parse("setglobal wrap")
    end

    test ":setglobal nowrap" do
      assert {:setglobal, :nowrap} = Parser.parse("setglobal nowrap")
    end
  end

  describe "parse/1 — substitute commands" do
    test ":%s/old/new/g parses to {:substitute, ...}" do
      assert {:substitute, "old", "new", [:global]} = Parser.parse("%s/old/new/g")
    end

    test ":s/old/new/ parses without flags" do
      assert {:substitute, "old", "new", []} = Parser.parse("s/old/new/")
    end

    test ":%s/old/new/gc parses both flags" do
      assert {:substitute, "old", "new", flags} = Parser.parse("%s/old/new/gc")
      assert :global in flags
      assert :confirm in flags
    end

    test ":%s/old/new parses without trailing delimiter" do
      assert {:substitute, "old", "new", []} = Parser.parse("%s/old/new")
    end

    test "handles escaped delimiters in pattern" do
      assert {:substitute, "a\\/b", "c", []} = Parser.parse("%s/a\\/b/c/")
    end

    test "handles empty replacement (delete)" do
      assert {:substitute, "old", "", [:global]} = Parser.parse("%s/old//g")
    end

    test "handles alternate delimiter #" do
      assert {:substitute, "old", "new", [:global]} = Parser.parse("%s#old#new#g")
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

  describe "set filetype commands" do
    test ":set ft=python parses to set_filetype" do
      assert {:set_filetype, ["python"]} = Parser.parse("set ft=python")
    end

    test ":set filetype=elixir parses to set_filetype" do
      assert {:set_filetype, ["elixir"]} = Parser.parse("set filetype=elixir")
    end

    test ":setf ruby parses to set_filetype" do
      assert {:set_filetype, ["ruby"]} = Parser.parse("setf ruby")
    end

    test ":setfiletype go parses to set_filetype" do
      assert {:set_filetype, ["go"]} = Parser.parse("setfiletype go")
    end

    test "trims whitespace from filetype name" do
      assert {:set_filetype, ["python"]} = Parser.parse("set ft=  python  ")
    end
  end
end
