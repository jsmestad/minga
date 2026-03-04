defmodule Minga.AutoPairTest do
  use ExUnit.Case, async: true

  alias Minga.AutoPair
  alias Minga.Buffer.Document

  # ── on_insert/3 — bracket pairs ──────────────────────────────────────────────

  describe "on_insert/3 with bracket pairs" do
    test "typing ( inserts pair" do
      buf = Document.new("hello")
      assert {:pair, "(", ")"} = AutoPair.on_insert(buf, {0, 5}, "(")
    end

    test "typing [ inserts pair" do
      buf = Document.new("")
      assert {:pair, "[", "]"} = AutoPair.on_insert(buf, {0, 0}, "[")
    end

    test "typing { inserts pair" do
      buf = Document.new("x")
      assert {:pair, "{", "}"} = AutoPair.on_insert(buf, {0, 1}, "{")
    end

    test "typing ( in middle of text inserts pair" do
      buf = Document.new("hello world")
      assert {:pair, "(", ")"} = AutoPair.on_insert(buf, {0, 5}, "(")
    end

    test "typing ( on empty buffer inserts pair" do
      buf = Document.new("")
      assert {:pair, "(", ")"} = AutoPair.on_insert(buf, {0, 0}, "(")
    end
  end

  # ── on_insert/3 — skip-over ─────────────────────────────────────────────────

  describe "on_insert/3 skip-over" do
    test "typing ) when cursor is on ) skips over" do
      buf = Document.new("()")
      assert {:skip, ")"} = AutoPair.on_insert(buf, {0, 1}, ")")
    end

    test "typing ] when cursor is on ] skips over" do
      buf = Document.new("[]")
      assert {:skip, "]"} = AutoPair.on_insert(buf, {0, 1}, "]")
    end

    test "typing } when cursor is on } skips over" do
      buf = Document.new("{}")
      assert {:skip, "}"} = AutoPair.on_insert(buf, {0, 1}, "}")
    end

    test "typing ) when cursor is NOT on ) inserts normally" do
      buf = Document.new("(x")
      assert {:passthrough, ")"} = AutoPair.on_insert(buf, {0, 1}, ")")
    end

    test "typing \" when cursor is on \" skips over" do
      buf = Document.new(~s(""))
      assert {:skip, "\""} = AutoPair.on_insert(buf, {0, 1}, "\"")
    end

    test "typing ' when cursor is on ' skips over" do
      buf = Document.new("''")
      assert {:skip, "'"} = AutoPair.on_insert(buf, {0, 1}, "'")
    end
  end

  # ── on_insert/3 — quote pairs ──────────────────────────────────────────────

  describe "on_insert/3 with quote pairs" do
    test "typing \" at end of line inserts pair" do
      buf = Document.new("hello ")
      assert {:pair, "\"", "\""} = AutoPair.on_insert(buf, {0, 6}, "\"")
    end

    test "typing ' at start of line inserts pair" do
      buf = Document.new("")
      assert {:pair, "'", "'"} = AutoPair.on_insert(buf, {0, 0}, "'")
    end

    test "typing backtick inserts pair" do
      buf = Document.new(" ")
      assert {:pair, "`", "`"} = AutoPair.on_insert(buf, {0, 0}, "`")
    end

    test "typing \" after a word character does not auto-pair" do
      buf = Document.new("hello")
      assert {:passthrough, "\""} = AutoPair.on_insert(buf, {0, 5}, "\"")
    end

    test "typing ' after a word character does not auto-pair (contractions)" do
      buf = Document.new("don")
      assert {:passthrough, "'"} = AutoPair.on_insert(buf, {0, 3}, "'")
    end

    test "typing ' after a space does auto-pair" do
      buf = Document.new("hello ")
      assert {:pair, "'", "'"} = AutoPair.on_insert(buf, {0, 6}, "'")
    end

    test "typing \" after ( does auto-pair" do
      buf = Document.new("(")
      assert {:pair, "\"", "\""} = AutoPair.on_insert(buf, {0, 1}, "\"")
    end

    test "typing \" at col 0 does auto-pair" do
      buf = Document.new("")
      assert {:pair, "\"", "\""} = AutoPair.on_insert(buf, {0, 0}, "\"")
    end
  end

  # ── on_insert/3 — passthrough ──────────────────────────────────────────────

  describe "on_insert/3 passthrough" do
    test "regular character passes through" do
      buf = Document.new("")
      assert {:passthrough, "a"} = AutoPair.on_insert(buf, {0, 0}, "a")
    end

    test "space passes through" do
      buf = Document.new("")
      assert {:passthrough, " "} = AutoPair.on_insert(buf, {0, 0}, " ")
    end

    test "closing bracket when not at matching char passes through" do
      buf = Document.new("hello")
      assert {:passthrough, ")"} = AutoPair.on_insert(buf, {0, 3}, ")")
    end
  end

  # ── on_insert/3 — multiline ───────────────────────────────────────────────

  describe "on_insert/3 multiline" do
    test "auto-pair on second line" do
      buf = Document.new("line1\nline2")
      assert {:pair, "(", ")"} = AutoPair.on_insert(buf, {1, 5}, "(")
    end

    test "skip-over on second line" do
      buf = Document.new("line1\n()")
      assert {:skip, ")"} = AutoPair.on_insert(buf, {1, 1}, ")")
    end
  end

  # ── on_backspace/2 ─────────────────────────────────────────────────────────

  describe "on_backspace/2" do
    test "backspace inside empty () deletes pair" do
      buf = Document.new("()")
      assert :delete_pair = AutoPair.on_backspace(buf, {0, 1})
    end

    test "backspace inside empty [] deletes pair" do
      buf = Document.new("[]")
      assert :delete_pair = AutoPair.on_backspace(buf, {0, 1})
    end

    test "backspace inside empty {} deletes pair" do
      buf = Document.new("{}")
      assert :delete_pair = AutoPair.on_backspace(buf, {0, 1})
    end

    test "backspace inside empty quotes deletes pair" do
      buf = Document.new(~s(""))
      assert :delete_pair = AutoPair.on_backspace(buf, {0, 1})
    end

    test "backspace inside empty single quotes deletes pair" do
      buf = Document.new("''")
      assert :delete_pair = AutoPair.on_backspace(buf, {0, 1})
    end

    test "backspace inside empty backticks deletes pair" do
      buf = Document.new("``")
      assert :delete_pair = AutoPair.on_backspace(buf, {0, 1})
    end

    test "backspace inside non-empty parens passes through" do
      buf = Document.new("(x)")
      assert :passthrough = AutoPair.on_backspace(buf, {0, 1})
    end

    test "backspace at col 0 passes through" do
      buf = Document.new("()")
      assert :passthrough = AutoPair.on_backspace(buf, {0, 0})
    end

    test "backspace with no pair before cursor passes through" do
      buf = Document.new("hello")
      assert :passthrough = AutoPair.on_backspace(buf, {0, 3})
    end

    test "backspace with opener before but wrong closer at cursor passes through" do
      buf = Document.new("(]")
      assert :passthrough = AutoPair.on_backspace(buf, {0, 1})
    end

    test "backspace at end of line (no char at cursor) passes through" do
      buf = Document.new("(")
      assert :passthrough = AutoPair.on_backspace(buf, {0, 1})
    end
  end

  # ── closing_for/1 ─────────────────────────────────────────────────────────

  describe "closing_for/1" do
    test "returns closing for opening brackets" do
      assert ")" = AutoPair.closing_for("(")
      assert "]" = AutoPair.closing_for("[")
      assert "}" = AutoPair.closing_for("{")
    end

    test "returns closing for quotes" do
      assert "\"" = AutoPair.closing_for("\"")
      assert "'" = AutoPair.closing_for("'")
      assert "`" = AutoPair.closing_for("`")
    end

    test "returns nil for non-pair characters" do
      assert nil == AutoPair.closing_for("a")
      assert nil == AutoPair.closing_for(")")
      assert nil == AutoPair.closing_for(" ")
    end
  end
end
