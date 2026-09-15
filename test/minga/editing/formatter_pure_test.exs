defmodule Minga.Editing.FormatterPureTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Formatter

  test "returns the default formatter for a known filetype" do
    assert Formatter.resolve_formatter(:elixir, "lib/foo.ex") ==
             "mix format --stdin-filename lib/foo.ex -"
  end

  test "returns nil for an unknown filetype" do
    assert Formatter.resolve_formatter(:unknown_lang) == nil
  end

  test "default formatters include the supported language families" do
    defaults = Formatter.default_formatters()

    assert Enum.all?([:elixir, :go, :rust, :python, :zig], &Map.has_key?(defaults, &1))
  end

  test "preserves trailing whitespace when trimming is disabled" do
    assert Formatter.apply_save_transforms("hello   \nworld  \n", :text) ==
             "hello   \nworld  \n"
  end

  test "preserves a missing final newline when insertion is disabled" do
    assert Formatter.apply_save_transforms("hello", :text) == "hello"
  end

  describe "apply_save_transforms/3" do
    test "trims line content without changing LF, CRLF, or mixed separators" do
      cases = [
        {"alpha  \nbeta\t\n", "alpha\nbeta\n"},
        {"alpha  \r\nbeta\t\r\n", "alpha\r\nbeta\r\n"},
        {"αβ  \r\n  \n你好\t\r\n", "αβ\r\n\n你好\r\n"}
      ]

      for {input, expected} <- cases do
        assert Formatter.apply_save_transforms(input, true, false) == expected
      end
    end

    test "inserts the final newline using the last complete separator" do
      cases = [
        {"alpha\nbeta", "alpha\nbeta\n"},
        {"alpha\r\nbeta", "alpha\r\nbeta\r\n"},
        {"alpha\r\nbeta\ngamma", "alpha\r\nbeta\ngamma\n"},
        {"alpha\nbeta\r\ngamma", "alpha\nbeta\r\ngamma\r\n"},
        {"alpha", "alpha\n"}
      ]

      for {input, expected} <- cases do
        assert Formatter.apply_save_transforms(input, false, true) == expected
      end
    end

    test "does not change empty content or duplicate an existing final newline" do
      for content <- ["", "alpha\n", "alpha\r\n"] do
        assert Formatter.apply_save_transforms(content, false, true) == content
      end
    end

    test "each transform and their combination are idempotent" do
      cases = [
        {"alpha  \r\nbeta\t", true, false},
        {"alpha\r\nbeta", false, true},
        {"alpha  \r\nbeta\t", true, true}
      ]

      for {content, trim?, final_newline?} <- cases do
        once = Formatter.apply_save_transforms(content, trim?, final_newline?)
        assert Formatter.apply_save_transforms(once, trim?, final_newline?) == once
      end
    end

    test "disabled transforms preserve content byte for byte" do
      content = "α  \r\n\t\n你好\r\n"
      assert Formatter.apply_save_transforms(content, false, false) == content
    end
  end
end
