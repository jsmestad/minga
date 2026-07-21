defmodule MingaEditor.Agent.DiffReviewTest do
  use ExUnit.Case, async: true

  alias Minga.Git
  alias MingaEditor.Agent.DiffReview

  describe "new/3" do
    test "returns nil when content is identical" do
      assert DiffReview.new("foo.ex", "hello\nworld\n", "hello\nworld\n") == nil
    end

    test "builds a review with hunks for added lines" do
      before = "line1\nline2\n"
      after_ = "line1\nline2\nnew_line\n"

      review = DiffReview.new("test.ex", before, after_)
      assert %DiffReview{} = review
      assert review.path == "test.ex"
      assert [_ | _] = review.hunks
      assert review.current_hunk_index == 0
      assert review.resolutions == %{}
    end

    test "builds a review with hunks for deleted lines" do
      before = "line1\nline2\nline3\n"
      after_ = "line1\nline3\n"

      review = DiffReview.new("test.ex", before, after_)
      assert %DiffReview{} = review
      assert [_ | _] = review.hunks
    end

    test "builds a review with hunks for modified lines" do
      before = "line1\nold_line\nline3\n"
      after_ = "line1\nnew_line\nline3\n"

      review = DiffReview.new("test.ex", before, after_)
      assert %DiffReview{} = review
      assert [_ | _] = review.hunks
    end

    test "stores after_lines and hunks" do
      review = DiffReview.new("f.ex", "a\nb\n", "a\nc\n")
      assert review.after_lines == ["a", "c", ""]
      assert [%{old_lines: ["b"]}] = review.hunks
      refute Map.has_key?(Map.from_struct(review), :before_lines)
    end

    test "detaches retained large old_lines from source binaries" do
      old_line = String.duplicate("x", 128)
      before = "one\n" <> old_line <> "\nthree"
      after_ = "one\nnew\nthree"

      review = DiffReview.new("test.ex", before, after_)

      assert [%{old_lines: [^old_line]}] = review.hunks

      assert :binary.referenced_byte_size(hd(hd(Enum.map(review.hunks, & &1.old_lines)))) ==
               byte_size(old_line)
    end
  end

  describe "materialized_lines/1" do
    test "applies rejected hunks in descending coordinate order" do
      before = "top\nold upper\nmiddle\ndeleted\nold lower\nbottom"
      after_ = "inserted\ntop\nnew upper\nmiddle\nnew lower\nbottom"
      review = DiffReview.new("test.ex", before, after_)

      review =
        review
        |> DiffReview.reject_current()
        |> DiffReview.reject_current()
        |> DiffReview.reject_current()

      assert DiffReview.materialized_lines(review) == String.split(before, "\n")
    end
  end

  describe "from_hunks/3" do
    test "returns nil when no hunks are provided" do
      assert DiffReview.from_hunks("f.ex", "a\n", []) == nil
    end

    test "builds additions from precomputed hunks and after-content" do
      review = from_contents("f.ex", "a\n", "a\nb\n")
      assert %DiffReview{} = review
      assert {added, 0} = DiffReview.summary(review)
      assert added > 0
    end

    test "builds deletions from precomputed hunks and after-content" do
      review = from_contents("f.ex", "a\nb\n", "a\n")
      assert %DiffReview{} = review
      assert {0, removed} = DiffReview.summary(review)
      assert removed > 0
    end

    test "builds modifications from precomputed hunks and after-content" do
      review = from_contents("f.ex", "a\nold\n", "a\nnew\n")
      assert %DiffReview{} = review
      assert {added, removed} = DiffReview.summary(review)
      assert added > 0
      assert removed > 0
    end
  end

  describe "next_hunk/1" do
    test "advances to the next hunk" do
      review = multi_hunk_review()
      assert review.current_hunk_index == 0

      review = DiffReview.next_hunk(review)
      assert review.current_hunk_index == 1
    end

    test "wraps around to first hunk" do
      review = multi_hunk_review()
      count = Enum.count(review.hunks)

      review = Enum.reduce(1..count, review, fn _, r -> DiffReview.next_hunk(r) end)
      assert review.current_hunk_index == 0
    end

    test "skips resolved hunks" do
      review = multi_hunk_review()
      review = DiffReview.accept_current(review)
      assert review.current_hunk_index != 0 or DiffReview.resolved?(review)
    end
  end

  describe "prev_hunk/1" do
    test "goes to the previous hunk" do
      review = multi_hunk_review()
      review = %{review | current_hunk_index: 1}

      review = DiffReview.prev_hunk(review)
      assert review.current_hunk_index == 0
    end

    test "wraps around to last hunk" do
      review = multi_hunk_review()
      review = DiffReview.prev_hunk(review)
      assert review.current_hunk_index == Enum.count(review.hunks) - 1
    end
  end

  describe "accept_current/1" do
    test "marks current hunk as accepted" do
      review = simple_review()
      review = DiffReview.accept_current(review)
      assert DiffReview.resolution_at(review, 0) == :accepted
    end

    test "advances to next unresolved hunk after accepting" do
      review = multi_hunk_review()
      original_idx = review.current_hunk_index
      review = DiffReview.accept_current(review)
      assert review.current_hunk_index != original_idx or DiffReview.resolved?(review)
    end
  end

  describe "reject_current/1" do
    test "marks current hunk as rejected" do
      review = simple_review()
      review = DiffReview.reject_current(review)
      assert DiffReview.resolution_at(review, 0) == :rejected
    end
  end

  describe "accept_all/1" do
    test "accepts all hunks" do
      review = multi_hunk_review()
      review = DiffReview.accept_all(review)
      assert DiffReview.resolved?(review)

      for idx <- 0..(Enum.count(review.hunks) - 1) do
        assert DiffReview.resolution_at(review, idx) == :accepted
      end
    end

    test "does not overwrite existing resolutions" do
      review = multi_hunk_review()
      review = DiffReview.reject_current(review)
      review = DiffReview.accept_all(review)

      assert DiffReview.resolution_at(review, 0) == :rejected
      assert DiffReview.resolved?(review)
    end
  end

  describe "reject_all/1" do
    test "rejects all hunks" do
      review = multi_hunk_review()
      review = DiffReview.reject_all(review)
      assert DiffReview.resolved?(review)

      for idx <- 0..(Enum.count(review.hunks) - 1) do
        assert DiffReview.resolution_at(review, idx) == :rejected
      end
    end
  end

  describe "resolved?/1" do
    test "false when no hunks are resolved" do
      review = simple_review()
      refute DiffReview.resolved?(review)
    end

    test "false when some hunks are resolved" do
      review = multi_hunk_review()
      review = DiffReview.accept_current(review)
      refute DiffReview.resolved?(review)
    end

    test "true when all hunks are resolved" do
      review = simple_review()
      review = DiffReview.accept_current(review)
      assert DiffReview.resolved?(review)
    end
  end

  describe "summary/1" do
    test "counts added lines" do
      review = DiffReview.new("f.ex", "a\n", "a\nb\nc\n")
      {added, removed} = DiffReview.summary(review)
      assert added > 0
      assert removed == 0
    end

    test "counts removed lines" do
      review = DiffReview.new("f.ex", "a\nb\nc\n", "a\n")
      {added, removed} = DiffReview.summary(review)
      assert added == 0
      assert removed > 0
    end

    test "counts both added and removed for modifications" do
      review = DiffReview.new("f.ex", "a\nold\nb\n", "a\nnew\nb\n")
      {added, removed} = DiffReview.summary(review)
      assert added > 0
      assert removed > 0
    end
  end

  describe "current_hunk/1" do
    test "returns the hunk at current index" do
      review = simple_review()
      hunk = DiffReview.current_hunk(review)
      assert hunk != nil
      assert hunk.type in [:added, :deleted, :modified]
    end
  end

  describe "current_hunk_line/1" do
    test "returns start line of current hunk" do
      review = simple_review()
      line = DiffReview.current_hunk_line(review)
      assert is_integer(line)
      assert line >= 0
    end
  end

  describe "to_display_lines/1" do
    test "includes hunk headers" do
      review = simple_review()
      lines = DiffReview.to_display_lines(review)
      headers = Enum.filter(lines, fn {_, type, _} -> type == :hunk_header end)
      assert [_ | _] = headers
    end

    test "includes added lines for additions" do
      review = DiffReview.new("f.ex", "a\n", "a\nb\n")
      lines = DiffReview.to_display_lines(review)
      added = Enum.filter(lines, fn {_, type, _} -> type == :added end)
      assert [_ | _] = added
    end

    test "includes removed lines for deletions" do
      review = DiffReview.new("f.ex", "a\nb\n", "a\n")
      lines = DiffReview.to_display_lines(review)
      removed = Enum.filter(lines, fn {_, type, _} -> type == :removed end)
      assert [_ | _] = removed
    end

    test "includes both removed and added for modifications" do
      review = DiffReview.new("f.ex", "a\nold\nb\n", "a\nnew\nb\n")
      lines = DiffReview.to_display_lines(review)
      added = Enum.filter(lines, fn {_, type, _} -> type == :added end)
      removed = Enum.filter(lines, fn {_, type, _} -> type == :removed end)
      assert [_ | _] = added
      assert [_ | _] = removed
    end

    test "hunk headers carry hunk index" do
      review = multi_hunk_review()
      lines = DiffReview.to_display_lines(review)
      headers = Enum.filter(lines, fn {_, type, _} -> type == :hunk_header end)

      indices = Enum.map(headers, fn {_, _, idx} -> idx end)
      assert 0 in indices
      assert 1 in indices
    end

    test "accepts a custom context line count" do
      review = DiffReview.new("f.ex", "a\nb\nc\n", "a\nB\nc\n")
      lines = DiffReview.to_display_lines(review, 0)

      refute Enum.any?(lines, fn {_text, type, _idx} -> type == :context end)
    end

    test "does not duplicate overlapping context lines for nearby hunks" do
      before = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"
      after_ = "l1\nL2\nl3\nl4\nL5\nl6\nl7\nl8\n"
      review = DiffReview.new("f.ex", before, after_)

      context_lines =
        review
        |> DiffReview.to_display_lines()
        |> Enum.filter(fn {_text, type, _idx} -> type == :context end)
        |> Enum.map(fn {text, _type, _idx} -> text end)

      assert context_lines == ["l1", "l3", "l4", "l6", "l7", "l8"]
    end

    test "renders removed and modified old text from hunks without full baseline lines" do
      review = DiffReview.new("f.ex", "a\nold\nc\n", "a\nnew\nc\n")
      lines = DiffReview.to_display_lines(review)

      assert {"old", :removed, 0} in lines
      assert {"new", :added, 0} in lines
      refute Map.has_key?(Map.from_struct(review), :before_lines)
    end
  end

  describe "update_after/3" do
    test "returns updated review with new after-content" do
      before = "line1\nline2\nline3"
      after_v1 = "line1\nmodified\nline3"
      review = DiffReview.new("test.ex", before, after_v1)

      after_v2 = "line1\nmodified\nline3\nnew_line"
      updated = update_after(review, before, after_v2)

      assert updated != nil
      assert updated.path == "test.ex"
      assert updated.after_lines == String.split(after_v2, "\n")
    end

    test "returns nil when after-content matches before-content" do
      before = "line1\nline2\nline3"
      after_v1 = "line1\nmodified\nline3"
      review = DiffReview.new("test.ex", before, after_v1)

      result = update_after(review, before, before)
      assert result == nil
    end

    test "preserves resolutions for unchanged hunks" do
      before = "aaa\nbbb\nccc\n\n\nddd\neee\nfff"
      after_v1 = "aaa\nBBB\nccc\n\n\nddd\neee\nfff"
      review = DiffReview.new("test.ex", before, after_v1)
      assert review != nil

      review = DiffReview.accept_current(review)
      assert DiffReview.resolution_at(review, 0) == :accepted

      after_v2 = "aaa\nBBB\nccc\n\n\nddd\neee\nfff\nnew_line"
      updated = update_after(review, before, after_v2)

      assert updated != nil
      assert DiffReview.resolution_at(updated, 0) == :accepted
    end

    test "preserves resolutions when an unchanged hunk shifts down" do
      before = "aaa\nbbb\nccc\nddd\neee\nfff\nggg"
      after_v1 = "aaa\nbbb\nccc\nddd\neee\nFFF\nggg"
      review = DiffReview.new("test.ex", before, after_v1)
      assert review != nil

      review = DiffReview.accept_current(review)
      assert DiffReview.resolution_at(review, 0) == :accepted

      after_v2 = "inserted\naaa\nbbb\nccc\nddd\neee\nFFF\nggg"
      updated = update_after(review, before, after_v2)

      assert updated != nil
      assert DiffReview.resolution_at(updated, 0) == nil
      assert DiffReview.resolution_at(updated, 1) == :accepted
    end

    test "preserves duplicate hunk resolutions one-to-one" do
      before = "a\nx\nb\nc\nd\nx\ne"
      after_v1 = "a\nX\nb\nc\nd\nX\ne"
      review = DiffReview.new("test.ex", before, after_v1)
      assert review != nil

      review = DiffReview.accept_current(review)
      review = DiffReview.reject_current(review)
      assert DiffReview.resolution_at(review, 0) == :accepted
      assert DiffReview.resolution_at(review, 1) == :rejected

      after_v2 = "a\nX\nb\nc\nd\nX\ne\nnew"
      updated = update_after(review, before, after_v2)

      assert updated != nil
      assert DiffReview.resolution_at(updated, 0) == :accepted
      assert DiffReview.resolution_at(updated, 1) == :rejected
      assert DiffReview.resolution_at(updated, 2) == nil
    end

    test "does not reuse one resolved hunk for multiple identical new hunks" do
      before = "a\nx\nb\nc\nd\nx\ne"
      after_v1 = "a\nX\nb\nc\nd\nx\ne"
      review = DiffReview.new("test.ex", before, after_v1)
      assert review != nil

      review = DiffReview.accept_current(review)
      assert DiffReview.resolution_at(review, 0) == :accepted

      after_v2 = "a\nX\nb\nc\nd\nX\ne"
      updated = update_after(review, before, after_v2)

      assert updated != nil
      assert DiffReview.resolution_at(updated, 0) == :accepted
      assert DiffReview.resolution_at(updated, 1) == nil
    end

    test "does not assign a lower hunk resolution to a new identical upper hunk" do
      before = "a\nx\nb\nc\nd\nx\ne"
      after_v1 = "a\nx\nb\nc\nd\nX\ne"
      review = DiffReview.new("test.ex", before, after_v1)
      assert review != nil

      review = DiffReview.accept_current(review)
      assert DiffReview.resolution_at(review, 0) == :accepted

      after_v2 = "a\nX\nb\nc\nd\nX\ne"
      updated = update_after(review, before, after_v2)

      assert updated != nil
      assert DiffReview.resolution_at(updated, 0) == nil
      assert DiffReview.resolution_at(updated, 1) == :accepted
    end

    test "drops resolutions for hunks that changed" do
      before = "aaa\nbbb\nccc"
      after_v1 = "aaa\nBBB\nccc"
      review = DiffReview.new("test.ex", before, after_v1)
      assert review != nil

      review = DiffReview.accept_current(review)
      assert DiffReview.resolution_at(review, 0) == :accepted

      after_v2 = "aaa\nbbb\nYYY"
      updated = update_after(review, before, after_v2)

      assert updated != nil
      assert DiffReview.resolution_at(updated, 0) == nil
    end

    test "clamps current_hunk_index to new hunk count" do
      before = "aaa\nbbb\nccc\nddd\neee"
      after_v1 = "aaa\nBBB\nccc\nDDD\neee"
      review = DiffReview.new("test.ex", before, after_v1)
      assert review != nil

      review = DiffReview.next_hunk(review)

      after_v2 = "aaa\nBBB\nccc\nddd\neee"
      updated = update_after(review, before, after_v2)

      assert updated != nil
      assert updated.current_hunk_index <= Enum.count(updated.hunks) - 1
    end

    test "repeated rejection follows the next unresolved hunk after reprojection" do
      before = numbered_lines(15)
      after_v1 = replace_lines(before, %{2 => "changed2", 8 => "changed8", 14 => "changed14"})
      review = DiffReview.new("test.ex", before, after_v1)
      assert Enum.count(review.hunks) == 3

      after_first_reject =
        review
        |> DiffReview.reject_current()
        |> reproject_rejection(before)

      assert Enum.count(after_first_reject.hunks) == 2
      assert current_added_lines(after_first_reject) == ["changed8"]

      after_second_reject =
        after_first_reject
        |> DiffReview.reject_current()
        |> reproject_rejection(before)

      assert Enum.count(after_second_reject.hunks) == 1
      assert current_added_lines(after_second_reject) == ["changed14"]
    end

    test "cumulative diff shows all changes from baseline" do
      original = "line1\nline2\nline3\nline4\nline5"
      after_v1 = "line1\nmodified2\nline3\nline4\nline5"
      review = DiffReview.new("test.ex", original, after_v1)
      assert review != nil

      after_v2 = "line1\nmodified2\nline3\nmodified4\nline5"
      updated = update_after(review, original, after_v2)

      assert updated != nil
      {added, removed} = DiffReview.summary(updated)
      assert added >= 2
      assert removed >= 2
    end
  end

  defp simple_review do
    DiffReview.new("test.ex", "line1\nline2\n", "line1\nchanged\n")
  end

  defp multi_hunk_review do
    before = """
    line1
    line2
    line3
    line4
    line5
    line6
    line7
    line8
    line9
    line10
    """

    after_ = """
    line1
    changed2
    line3
    line4
    line5
    line6
    line7
    changed8
    line9
    line10
    """

    DiffReview.new("test.ex", before, after_)
  end

  defp from_contents(path, before, after_) do
    DiffReview.from_hunks(path, after_, diff_hunks(before, after_))
  end

  defp update_after(review, before, after_) do
    DiffReview.update_after(review, after_, diff_hunks(before, after_))
  end

  defp reproject_rejection(review, before) do
    after_rejection = review |> DiffReview.materialized_lines() |> Enum.join("\n")
    update_after(review, before, after_rejection)
  end

  defp numbered_lines(count) do
    1..count
    |> Enum.map_join("\n", fn line -> "line#{line}" end)
  end

  defp replace_lines(content, replacements) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {line, number} -> Map.get(replacements, number, line) end)
  end

  defp current_added_lines(review) do
    hunk = DiffReview.current_hunk(review)
    Enum.slice(review.after_lines, hunk.start_line, hunk.count)
  end

  defp diff_hunks(before, after_) do
    Git.diff_lines(String.split(before, "\n"), String.split(after_, "\n"))
  end
end
