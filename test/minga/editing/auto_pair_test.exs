defmodule Minga.Editing.AutoPairTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Editing.AutoPair

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

  describe "on_insert/3 delimiter decisions" do
    test "maps each delimiter class and cursor context to the existing action" do
      cases = [
        {"opening delimiter", "text", {0, 2}, "(", {:pair, "(", ")"}},
        {"matching closing delimiter", "()", {0, 1}, ")", {:skip, ")"}},
        {"non-matching closing delimiter", "(x", {0, 1}, ")", {:passthrough, ")"}},
        {"matching quote", ~s(""), {0, 1}, "\"", {:skip, "\""}},
        {"matching quote after word character", ~s(word"), {0, 4}, "\"", {:skip, "\""}},
        {"quote after a word character", "word", {0, 4}, "\"", {:passthrough, "\""}},
        {"quote after ordinary text", "word ", {0, 5}, "\"", {:pair, "\"", "\""}},
        {"plain character", "text", {0, 2}, "x", {:passthrough, "x"}}
      ]

      Enum.each(cases, fn {label, text, position, char, expected} ->
        assert AutoPair.on_insert(Document.new(text), position, char) == expected, label
      end)
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

    test "only ASCII letters, digits, and underscore count as word characters" do
      cases = [
        {"A", {:passthrough, "\""}},
        {"z", {:passthrough, "\""}},
        {"0", {:passthrough, "\""}},
        {"9", {:passthrough, "\""}},
        {"_", {:passthrough, "\""}},
        {"é", {:pair, "\"", "\""}}
      ]

      Enum.each(cases, fn {text, expected} ->
        position = {0, byte_size(text)}
        assert AutoPair.on_insert(Document.new(text), position, "\"") == expected
      end)
    end
  end

  describe "on_insert/3 byte-offset boundaries" do
    test "preserves empty, missing, zero, end, and beyond-end behavior" do
      cases = [
        {"empty line", "", {0, 0}, "\"", {:pair, "\"", "\""}},
        {"missing line", "text", {1, 0}, "\"", {:pair, "\"", "\""}},
        {"column zero", "text", {0, 0}, "\"", {:pair, "\"", "\""}},
        {"end of line", "text ", {0, 5}, "\"", {:pair, "\"", "\""}},
        {"beyond end after a word", "text", {0, 99}, "\"", {:passthrough, "\""}},
        {"beyond end closing", ")", {0, 99}, ")", {:passthrough, ")"}}
      ]

      Enum.each(cases, fn {label, text, position, char, expected} ->
        assert AutoPair.on_insert(Document.new(text), position, char) == expected, label
      end)
    end

    test "preserves behavior at and inside multibyte and combining graphemes" do
      cases = [
        {"inside multibyte grapheme", "🥨)", {0, 1}, ")", {:passthrough, ")"}},
        {"after multibyte grapheme", "🥨)", {0, 4}, ")", {:skip, ")"}},
        {"inside multibyte grapheme for previous lookup", "é", {0, 1}, "\"", {:pair, "\"", "\""}},
        {"inside combining grapheme", "e\u0301", {0, 1}, "\"", {:pair, "\"", "\""}},
        {"inside combining codepoint", "e\u0301)", {0, 2}, ")", {:passthrough, ")"}},
        {"after multibyte grapheme and ASCII word", "éa", {0, 3}, "\"", {:passthrough, "\""}}
      ]

      Enum.each(cases, fn {label, text, position, char, expected} ->
        assert AutoPair.on_insert(Document.new(text), position, char) == expected, label
      end)
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

    test "backspace on a missing line or beyond the line passes through" do
      buf = Document.new("()")
      assert :passthrough = AutoPair.on_backspace(buf, {1, 1})
      assert :passthrough = AutoPair.on_backspace(buf, {0, 99})
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
