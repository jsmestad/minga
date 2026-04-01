defmodule MingaEditor.Agent.DiffReviewTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.DiffReview

  # ── new/3 ───────────────────────────────────────────────────────────────────

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
      assert review.hunks != []
      assert review.current_hunk_index == 0
      assert review.resolutions == %{}
    end

    test "builds a review with hunks for deleted lines" do
      before = "line1\nline2\nline3\n"
      after_ = "line1\nline3\n"

      review = DiffReview.new("test.ex", before, after_)
      assert %DiffReview{} = review
      assert review.hunks != []
    end

    test "builds a review with hunks for modified lines" do
      before = "line1\nold_line\nline3\n"
      after_ = "line1\nnew_line\nline3\n"

      review = DiffReview.new("test.ex", before, after_)
      assert %DiffReview{} = review
      assert review.hunks != []
    end

    test "stores before_lines and after_lines" do
      review = DiffReview.new("f.ex", "a\nb\n", "a\nc\n")
      assert review.before_lines == ["a", "b", ""]
      assert review.after_lines == ["a", "c", ""]
    end
  end

  # ── Navigation ──────────────────────────────────────────────────────────────

  describe "next_hunk/1" do
    test "advances to the next hunk" do
      review = multi_hunk_review()
      assert review.current_hunk_index == 0

      review = DiffReview.next_hunk(review)
      assert review.current_hunk_index == 1
    end

    test "wraps around to first hunk" do
      review = multi_hunk_review()
      count = length(review.hunks)

      review = Enum.reduce(1..count, review, fn _, r -> DiffReview.next_hunk(r) end)
      assert review.current_hunk_index == 0
    end

    test "skips resolved hunks" do
      review = multi_hunk_review()
      review = DiffReview.accept_current(review)
      # Should have advanced past hunk 0 (now accepted)
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
      # Should wrap to last hunk
      assert review.current_hunk_index == length(review.hunks) - 1
    end
  end

  # ── Resolution ──────────────────────────────────────────────────────────────

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

      for idx <- 0..(length(review.hunks) - 1) do
        assert DiffReview.resolution_at(review, idx) == :accepted
      end
    end

    test "does not overwrite existing resolutions" do
      review = multi_hunk_review()
      review = DiffReview.reject_current(review)
      review = DiffReview.accept_all(review)

      # First hunk was rejected, should stay rejected
      assert DiffReview.resolution_at(review, 0) == :rejected
      assert DiffReview.resolved?(review)
    end
  end

  describe "reject_all/1" do
    test "rejects all hunks" do
      review = multi_hunk_review()
      review = DiffReview.reject_all(review)
      assert DiffReview.resolved?(review)

      for idx <- 0..(length(review.hunks) - 1) do
        assert DiffReview.resolution_at(review, idx) == :rejected
      end
    end
  end

  # ── Queries ─────────────────────────────────────────────────────────────────

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

  # ── Display lines ──────────────────────────────────────────────────────────

  describe "to_display_lines/1" do
    test "includes hunk headers" do
      review = simple_review()
      lines = DiffReview.to_display_lines(review)
      headers = Enum.filter(lines, fn {_, type, _} -> type == :hunk_header end)
      assert headers != []
    end

    test "includes added lines for additions" do
      review = DiffReview.new("f.ex", "a\n", "a\nb\n")
      lines = DiffReview.to_display_lines(review)
      added = Enum.filter(lines, fn {_, type, _} -> type == :added end)
      assert added != []
    end

    test "includes removed lines for deletions" do
      review = DiffReview.new("f.ex", "a\nb\n", "a\n")
      lines = DiffReview.to_display_lines(review)
      removed = Enum.filter(lines, fn {_, type, _} -> type == :removed end)
      assert removed != []
    end

    test "includes both removed and added for modifications" do
      review = DiffReview.new("f.ex", "a\nold\nb\n", "a\nnew\nb\n")
      lines = DiffReview.to_display_lines(review)
      added = Enum.filter(lines, fn {_, type, _} -> type == :added end)
      removed = Enum.filter(lines, fn {_, type, _} -> type == :removed end)
      assert added != []
      assert removed != []
    end

    test "hunk headers carry hunk index" do
      review = multi_hunk_review()
      lines = DiffReview.to_display_lines(review)
      headers = Enum.filter(lines, fn {_, type, _} -> type == :hunk_header end)

      indices = Enum.map(headers, fn {_, _, idx} -> idx end)
      assert 0 in indices
      assert 1 in indices
    end
  end

  # ── update_after/2 ──────────────────────────────────────────────────────────

  describe "update_after/2" do
    test "returns updated review with new after-content" do
      before = "line1\nline2\nline3"
      after_v1 = "line1\nmodified\nline3"
      review = DiffReview.new("test.ex", before, after_v1)

      after_v2 = "line1\nmodified\nline3\nnew_line"
      updated = DiffReview.update_after(review, after_v2)

      assert updated != nil
      assert updated.path == "test.ex"
      assert updated.before_lines == String.split(before, "\n")
      assert updated.after_lines == String.split(after_v2, "\n")
    end

    test "returns nil when after-content matches before-content" do
      before = "line1\nline2\nline3"
      after_v1 = "line1\nmodified\nline3"
      review = DiffReview.new("test.ex", before, after_v1)

      # Revert to original
      result = DiffReview.update_after(review, before)
      assert result == nil
    end

    test "preserves resolutions for unchanged hunks" do
      before = "aaa\nbbb\nccc\n\n\nddd\neee\nfff"
      after_v1 = "aaa\nBBB\nccc\n\n\nddd\neee\nfff"
      review = DiffReview.new("test.ex", before, after_v1)
      assert review != nil

      # Accept the first hunk
      review = DiffReview.accept_current(review)
      assert DiffReview.resolution_at(review, 0) == :accepted

      # Second edit: add a new line at the end (original hunk unchanged)
      after_v2 = "aaa\nBBB\nccc\n\n\nddd\neee\nfff\nnew_line"
      updated = DiffReview.update_after(review, after_v2)

      assert updated != nil
      # The original hunk's resolution should be preserved
      # (It's the same modification: bbb -> BBB at the same position)
      assert DiffReview.resolution_at(updated, 0) == :accepted
    end

    test "drops resolutions for hunks that changed" do
      before = "aaa\nbbb\nccc"
      after_v1 = "aaa\nBBB\nccc"
      review = DiffReview.new("test.ex", before, after_v1)
      assert review != nil

      # Accept the hunk
      review = DiffReview.accept_current(review)
      assert DiffReview.resolution_at(review, 0) == :accepted

      # Second edit: completely change the after-content so the hunk signature won't match.
      # The baseline stays "aaa\nbbb\nccc" but the after changes to modify a different line.
      after_v2 = "aaa\nbbb\nYYY"
      updated = DiffReview.update_after(review, after_v2)

      assert updated != nil
      # The hunk signature changed (different line changed), so resolution should be dropped
      assert DiffReview.resolution_at(updated, 0) == nil
    end

    test "clamps current_hunk_index to new hunk count" do
      before = "aaa\nbbb\nccc\nddd\neee"
      after_v1 = "aaa\nBBB\nccc\nDDD\neee"
      review = DiffReview.new("test.ex", before, after_v1)
      assert review != nil

      # Navigate to the last hunk
      review = DiffReview.next_hunk(review)

      # Second edit removes one of the changes
      after_v2 = "aaa\nBBB\nccc\nddd\neee"
      updated = DiffReview.update_after(review, after_v2)

      assert updated != nil
      assert updated.current_hunk_index <= length(updated.hunks) - 1
    end

    test "cumulative diff shows all changes from baseline" do
      # Simulate: original file, then two sequential edits
      original = "line1\nline2\nline3\nline4\nline5"

      # First edit: modify line 2
      after_v1 = "line1\nmodified2\nline3\nline4\nline5"
      review = DiffReview.new("test.ex", original, after_v1)
      assert review != nil

      # Second edit: also modify line 4
      after_v2 = "line1\nmodified2\nline3\nmodified4\nline5"
      updated = DiffReview.update_after(review, after_v2)

      assert updated != nil
      # Should have hunks covering BOTH modifications (line 2 AND line 4)
      {added, removed} = DiffReview.summary(updated)
      assert added >= 2
      assert removed >= 2
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # A review with exactly one hunk
  defp simple_review do
    DiffReview.new("test.ex", "line1\nline2\n", "line1\nchanged\n")
  end

  # A review with multiple hunks (changes in different parts of the file)
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
end
