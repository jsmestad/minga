defmodule Minga.Editing.LineEditTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Minga.Editing.LineEdit

  @ctrl 0x02

  describe "edit_for_key/1" do
    test "maps the readline control keys and nothing else" do
      assert LineEdit.edit_for_key({?a, @ctrl}) == :line_start
      assert LineEdit.edit_for_key({?e, @ctrl}) == :line_end
      assert LineEdit.edit_for_key({?h, @ctrl}) == :delete_backward
      assert LineEdit.edit_for_key({?w, @ctrl}) == :delete_word_backward
      assert LineEdit.edit_for_key({?u, @ctrl}) == :delete_to_start
      assert LineEdit.edit_for_key({?k, @ctrl}) == :delete_to_end

      assert LineEdit.edit_for_key({?a, 0}) == nil
      assert LineEdit.edit_for_key({?j, @ctrl}) == nil
      assert LineEdit.edit_for_key({?a, @ctrl ||| 0x01}) == nil
    end
  end

  describe "apply/3" do
    test "every edit on empty text leaves it empty with the cursor at zero" do
      for edit <- edits() do
        assert LineEdit.apply(edit, "", 0) == {"", 0}
      end
    end

    test "edits at the start and the end of the line" do
      assert LineEdit.apply(:delete_backward, "abc", 0) == {"abc", 0}
      assert LineEdit.apply(:delete_word_backward, "abc", 0) == {"abc", 0}
      assert LineEdit.apply(:delete_to_start, "abc", 0) == {"abc", 0}
      assert LineEdit.apply(:delete_to_end, "abc", 3) == {"abc", 3}
      assert LineEdit.apply(:line_end, "abc", 0) == {"abc", 3}
      assert LineEdit.apply(:line_start, "abc", 3) == {"abc", 0}
    end

    test "⌃W deletes trailing whitespace and then the word before it" do
      assert LineEdit.apply(:delete_word_backward, "foo bar  ", 9) == {"foo ", 4}
      assert LineEdit.apply(:delete_word_backward, "foo bar baz", 7) == {"foo  baz", 4}
      assert LineEdit.apply(:delete_word_backward, "path/to/file", 12) == {"", 0}
    end

    test "⌃U and ⌃K split the line at the cursor" do
      assert LineEdit.apply(:delete_to_start, "foo bar", 4) == {"bar", 0}
      assert LineEdit.apply(:delete_to_end, "foo bar", 4) == {"foo ", 4}
    end

    test "positions count graphemes, not bytes or codepoints" do
      text = "é 界 😀"
      assert LineEdit.apply(:delete_backward, text, 5) == {"é 界 ", 4}
      assert LineEdit.apply(:delete_word_backward, text, 3) == {"e\u0301  😀", 2}
      assert LineEdit.apply(:line_end, text, 0) == {text, 5}
    end

    test "a cursor past the end is clamped to the end" do
      assert LineEdit.apply(:delete_backward, "ab", 10) == {"a", 1}
    end

    property "edits keep the cursor inside the resulting text" do
      check all(
              text <- string(:printable, max_length: 20),
              cursor <- integer(0..25),
              edit <- member_of(edits())
            ) do
        {next, next_cursor} = LineEdit.apply(edit, text, cursor)
        assert next_cursor <= String.length(next)
      end
    end
  end

  defp edits,
    do: [
      :line_start,
      :line_end,
      :delete_backward,
      :delete_word_backward,
      :delete_to_start,
      :delete_to_end
    ]
end
