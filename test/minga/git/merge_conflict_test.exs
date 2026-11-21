defmodule Minga.Git.MergeConflictTest do
  use ExUnit.Case, async: true

  alias Minga.Git.MergeConflict
  alias Minga.Git.MergeConflict.Entry
  alias Minga.Git.MergeConflict.Region

  describe "parse/1" do
    test "parses a standard conflict block" do
      content = "before\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\nafter"

      assert [region] = MergeConflict.parse(content)
      assert %Region{} = region
      assert region.start_line == 1
      assert region.current_range == {2, 2}
      assert region.separator_line == 3
      assert region.incoming_range == {4, 4}
      assert region.end_line == 5
      assert region.current_label == "HEAD"
      assert region.incoming_label == "branch"
      assert region.current_lines == ["ours"]
      assert region.incoming_lines == ["theirs"]
    end

    test "parses a diff3 conflict block" do
      content = "<<<<<<< ours\ncurrent\n||||||| base\nbase\n=======\nincoming\n>>>>>>> theirs"

      assert [region] = MergeConflict.parse(content)
      assert region.current_lines == ["current"]
      assert region.base_lines == ["base"]
      assert region.incoming_lines == ["incoming"]
      assert region.base_label == "base"
      assert region.base_marker_line == 2
      assert region.base_range == {3, 3}
    end

    test "ignores incomplete conflict blocks" do
      content = "<<<<<<< HEAD\nours\n=======\nmissing end"

      assert MergeConflict.parse(content) == []
    end

    test "keeps unexpected markers in the active side and consumes the first matching delimiters" do
      lines = [
        "orphan",
        "<<<<<<<< ours",
        "<<<<<<< nested",
        ">>>>>>> early",
        "||||||| base",
        "||||||| second base",
        "======= separator label",
        "======= body",
        "<<<<<<< body",
        ">>>>>>>theirs",
        ">>>>>>> outside"
      ]

      assert [
               %Region{
                 start_line: 1,
                 base_marker_line: 4,
                 separator_line: 6,
                 end_line: 9,
                 current_label: "< ours",
                 base_label: "base",
                 incoming_label: "theirs",
                 current_lines: ["<<<<<<< nested", ">>>>>>> early"],
                 base_lines: ["||||||| second base"],
                 incoming_lines: ["======= body", "<<<<<<< body"]
               }
             ] = MergeConflict.parse_lines(lines)
    end

    test "keeps adjacent completed conflicts and drops the last unfinished side" do
      completed = ["<<<<<<<", "=======", ">>>>>>>", "<<<<<<<", "|||||||", "=======", "", ">>>>>>>"]

      for unfinished <- [["<<<<<<<"], ["<<<<<<<", "|||||||"], ["<<<<<<<", "======="]] do
        assert [
                 %Region{
                   start_line: 0,
                   end_line: 2,
                   current_range: {1, 0},
                   incoming_range: {2, 1},
                   current_lines: [],
                   base_lines: nil,
                   incoming_lines: []
                 },
                 %Region{
                   start_line: 3,
                   end_line: 7,
                   base_range: {5, 4},
                   base_lines: [],
                   incoming_lines: [""]
                 }
               ] = MergeConflict.parse_lines(completed ++ unfinished)
      end
    end
  end

  describe "navigation helpers" do
    test "finds containing, next, and previous regions with wrapping" do
      regions =
        MergeConflict.parse(
          "<<<<<<< A\na\n=======\nb\n>>>>>>> B\nmid\n<<<<<<< C\nc\n=======\nd\n>>>>>>> D"
        )

      [first, second] = regions

      assert MergeConflict.at_line(regions, 2) == first
      assert MergeConflict.next_after(regions, 5) == second
      assert MergeConflict.next_after(regions, 2) == second
      assert MergeConflict.next_after(regions, 10) == first
      assert MergeConflict.prev_before(regions, 10) == second
      assert MergeConflict.prev_before(regions, 0) == second
    end
  end

  describe "replacement helpers" do
    test "replaces current, incoming, or both sides in diff3 conflicts" do
      content =
        "before\n<<<<<<< ours\ncurrent\n||||||| base\nbase\n=======\nincoming\n>>>>>>> theirs\nafter"

      assert {:ok, "before\ncurrent\nafter"} = MergeConflict.replace_at_line(content, 1, :current)

      assert {:ok, "before\nincoming\nafter"} =
               MergeConflict.replace_at_line(content, 1, :incoming)

      assert {:ok, "before\ncurrent\nincoming\nafter"} =
               MergeConflict.replace_at_line(content, 1, :both)
    end

    test "returns not found when no conflict contains the line" do
      assert :not_found = MergeConflict.replace_at_line("plain\ntext", 0, :current)
    end

    test "an empty entry removes its marker lines without adding a separator" do
      conflict = "<<<<<<<\n=======\n>>>>>>>"

      for {left, right, expected} <- [
            {"", "\nR", "R"},
            {"L\n", "\nR", "L\nR"},
            {"L\n", "", "L"},
            {"", "", ""},
            {"", "\n", ""},
            {"L\n", "\n", "L\n"}
          ] do
        start = if left == "", do: 0, else: 1
        entry = Entry.new(start, nil, start + 1, start + 2, "", nil, "")
        assert MergeConflict.replace_region(left <> conflict <> right, entry, :both) == expected
      end
    end

    test "entry choices preserve a blank line from CRLF and exclude diff3 base text" do
      content = "L\r\n<<<<<<< ours\r\n\r\n||||||| base\r\nbase\r\n=======\r\n>>>>>>> theirs\r\nR"
      entry = Entry.new(1, 3, 5, 6, "ours", "base", "theirs")

      assert MergeConflict.replace_region(content, entry, :current) == "L\r\n\r\nR"
      assert MergeConflict.replace_region(content, entry, :incoming) == "L\r\nR"
      assert MergeConflict.replace_region(content, entry, :both) == "L\r\n\r\nR"
    end
  end
end
