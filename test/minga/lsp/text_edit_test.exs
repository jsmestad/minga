defmodule Minga.LSP.TextEditTest do
  @moduledoc "Protocol-correct LSP text edit application tests."

  use ExUnit.Case, async: true

  alias Minga.LSP.TextEdit

  test "applies unordered edits against the original snapshot without positional shift" do
    edits = [edit(0, 4, 0, 6, "EF"), edit(0, 0, 0, 2, "AB")]

    assert TextEdit.apply("abcdef", edits, :utf8) == {:ok, "ABcdEF"}
  end

  test "applies an edit spanning multiple lines" do
    edits = [edit(0, 2, 2, 2, "X\nY")]

    assert TextEdit.apply("abc\ndef\nghi", edits, :utf8) == {:ok, "abX\nYi"}
  end

  test "converts non-ASCII positions for every negotiated encoding" do
    content = "a😀éb"

    assert TextEdit.apply(content, [edit(0, 1, 0, 5, "X")], :utf8) == {:ok, "aXéb"}
    assert TextEdit.apply(content, [edit(0, 1, 0, 3, "X")], :utf16) == {:ok, "aXéb"}
    assert TextEdit.apply(content, [edit(0, 1, 0, 2, "X")], :utf32) == {:ok, "aXéb"}
  end

  test "rejects overlapping ranges without producing partial content" do
    edits = [edit(0, 0, 0, 3, "first"), edit(0, 2, 0, 4, "second")]

    assert TextEdit.apply("abcdef", edits, :utf8) == {:error, :overlapping_edits}
  end

  test "preserves response order for multiple insertions at the same position" do
    edits = [edit(0, 2, 0, 2, "first"), edit(0, 2, 0, 2, "second")]

    assert TextEdit.apply("abcdef", edits, :utf8) == {:ok, "abfirstsecondcdef"}
  end

  test "preserves CRLF and lone-CR line endings while resolving logical lines" do
    assert TextEdit.apply("a\r\nb", [edit(1, 0, 1, 1, "B")], :utf8) == {:ok, "a\r\nB"}
    assert TextEdit.apply("a\rb", [edit(1, 0, 1, 1, "B")], :utf8) == {:ok, "a\rB"}
    assert TextEdit.apply("a\r\nb", [edit(0, 2, 0, 2, "X")], :utf8) == {:error, :invalid_edit}
  end

  test "rejects invalid lines, reversed ranges, and malformed edits" do
    assert TextEdit.apply("abc", [edit(1, 0, 1, 0, "x")], :utf8) ==
             {:error, :invalid_edit}

    assert TextEdit.apply("abc", [edit(0, 2, 0, 1, "x")], :utf8) ==
             {:error, :invalid_edit}

    assert TextEdit.apply("abc", [%{"newText" => "x"}], :utf8) ==
             {:error, :invalid_edit}
  end

  test "rejects positions outside encoding boundaries" do
    assert TextEdit.apply("é", [edit(0, 1, 0, 2, "x")], :utf8) ==
             {:error, :invalid_edit}

    assert TextEdit.apply("😀", [edit(0, 1, 0, 2, "x")], :utf16) ==
             {:error, :invalid_edit}

    assert TextEdit.apply("é", [edit(0, 2, 0, 3, "x")], :utf32) ==
             {:error, :invalid_edit}
  end

  defp edit(start_line, start_character, end_line, end_character, new_text) do
    %{
      "range" => %{
        "start" => %{"line" => start_line, "character" => start_character},
        "end" => %{"line" => end_line, "character" => end_character}
      },
      "newText" => new_text
    }
  end
end
