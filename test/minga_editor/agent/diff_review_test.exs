defmodule MingaEditor.Agent.DiffReviewTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Diff
  alias Minga.Git
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.FileChange

  test "adjacent merge conflicts can be decided independently without changing resolved context" do
    review =
      DiffReview.from_merge_conflicts("conflict.ex", [
        {:resolved, ["preserved"]},
        {:conflict, ["新增"], []},
        {:conflict, [], ["親"]},
        {:resolved, ["tail", ""]}
      ])

    resolved = review |> DiffReview.accept_current() |> DiffReview.reject_current()

    assert DiffReview.resolved?(resolved)
    assert DiffReview.materialized_lines(resolved) == ["preserved", "新增", "親", "tail", ""]
  end

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

    test "restores tied deletions in their original order and uses original rejection indexes" do
      review = tied_deletion_review()
      original = ["p", "A", "B", "C", "t", ""]

      assert DiffReview.original_lines(review) == original
      assert review |> DiffReview.reject_all() |> DiffReview.materialized_lines() == original
      assert DiffReview.materialized_lines(review) == ["p", "N", "t", ""]

      second_rejected = review |> DiffReview.next_hunk() |> DiffReview.reject_current()
      assert DiffReview.materialized_lines(second_rejected) == ["p", "B", "N", "t", ""]
    end

    test "matches reverse supplied-order reverts for every explicit rejection subset" do
      cases = [
        {"z", [hunk(:deleted, 1, 0, ["A"]), hunk(:deleted, 1, 0, ["B"])]},
        {"z", [hunk(:deleted, 3, 0, ["A"]), hunk(:deleted, 3, 0, ["B"])]},
        {"z\ny", [hunk(:deleted, 1, 0, ["A"]), hunk(:added, 0, 1, [])]},
        {"a\nb\nc", [hunk(:modified, 0, 2, ["A"]), hunk(:modified, 1, 2, ["B"])]},
        {"z", [hunk(:modified, 0, 2, ["A"]), hunk(:deleted, 2, 0, ["B"])]}
      ]

      for {after_content, hunks} <- cases do
        review = DiffReview.from_hunks("f.ex", after_content, hunks)
        assert_revert_subsets(review)
      end
    end

    test "matches reverse-order reverts for a recorded review" do
      change = %FileChange{
        path: "f.ex",
        before_content: "top\nold upper\nmiddle\nold lower\nbottom",
        after_content: "inserted\ntop\nnew upper\nmiddle\nnew lower\nbottom",
        tool_call_id: "tc1",
        tool_name: "edit_file"
      }

      timeline = EditTimeline.new() |> EditTimeline.record_edit(change)
      hunks = EditTimeline.cumulative_hunks(timeline, change.path)
      review = DiffReview.from_hunks(change.path, change.after_content, hunks)

      assert_revert_subsets(review)
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

  test "manual navigation wraps in either direction and uses the neighbor when all are resolved" do
    review =
      DiffReview.from_merge_conflicts(
        "f.ex",
        Enum.map(["A", "B", "C", "D"], &{:conflict, [&1], ["old"]})
      )

    review =
      review
      |> DiffReview.accept_current()
      |> DiffReview.next_hunk()
      |> DiffReview.reject_current()

    assert review.current_hunk_index == 3
    wrapped = DiffReview.next_hunk(review)
    assert wrapped.current_hunk_index == 1
    assert wrapped.resolutions == %{0 => :accepted, 2 => :rejected}
    assert DiffReview.prev_hunk(wrapped) == review

    review = DiffReview.accept_current(review)
    assert review.current_hunk_index == 1
    assert DiffReview.next_hunk(review) == review
    assert DiffReview.prev_hunk(review) == review

    resolved = DiffReview.reject_current(review)
    assert DiffReview.resolved?(resolved)
    assert resolved.current_hunk_index == 1
    assert DiffReview.next_hunk(resolved) == %{resolved | current_hunk_index: 2}
    assert DiffReview.prev_hunk(resolved) == %{resolved | current_hunk_index: 0}
  end

  test "navigation leaves an empty review unchanged" do
    empty = %DiffReview{path: "f.ex", after_lines: ["a"], hunks: []}
    assert DiffReview.next_hunk(empty) == empty
    assert DiffReview.prev_hunk(empty) == empty
    refute DiffReview.resolved?(empty)
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
      headers = Enum.filter(lines, &(&1.kind == :hunk_header))
      assert [_ | _] = headers
    end

    test "includes added lines for additions" do
      review = DiffReview.new("f.ex", "a\n", "a\nb\n")
      lines = DiffReview.to_display_lines(review)
      added = Enum.filter(lines, &(&1.kind == :added))
      assert [_ | _] = added
    end

    test "includes removed lines for deletions" do
      review = DiffReview.new("f.ex", "a\nb\n", "a\n")
      lines = DiffReview.to_display_lines(review)
      removed = Enum.filter(lines, &(&1.kind == :removed))
      assert [_ | _] = removed
    end

    test "includes both removed and added for modifications" do
      review = DiffReview.new("f.ex", "a\nold\nb\n", "a\nnew\nb\n")
      lines = DiffReview.to_display_lines(review)
      added = Enum.filter(lines, &(&1.kind == :added))
      removed = Enum.filter(lines, &(&1.kind == :removed))
      assert [_ | _] = added
      assert [_ | _] = removed
    end

    test "hunk headers carry hunk index" do
      review = multi_hunk_review()
      lines = DiffReview.to_display_lines(review)
      headers = Enum.filter(lines, &(&1.kind == :hunk_header))

      indices = Enum.map(headers, & &1.hunk_index)
      assert 0 in indices
      assert 1 in indices
    end

    test "accepts a custom context line count" do
      review = DiffReview.new("f.ex", "a\nb\nc\n", "a\nB\nc\n")
      lines = DiffReview.to_display_lines(review, 0)

      refute Enum.any?(lines, &(&1.kind == :context))
    end

    test "does not duplicate overlapping context lines for nearby hunks" do
      before = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"
      after_ = "l1\nL2\nl3\nl4\nL5\nl6\nl7\nl8\n"
      review = DiffReview.new("f.ex", before, after_)

      context_lines =
        review
        |> DiffReview.to_display_lines()
        |> Enum.filter(&(&1.kind == :context))
        |> Enum.map(& &1.text)

      assert context_lines == ["l1", "l3", "l4", "l6", "l7", "l8"]
    end

    test "renders removed and modified old text from hunks without full baseline lines" do
      review = DiffReview.new("f.ex", "a\nold\nc\n", "a\nnew\nc\n")
      lines = DiffReview.to_display_lines(review)

      assert Enum.any?(lines, &match?(%{text: "old", kind: :removed, hunk_index: 0}, &1))
      assert Enum.any?(lines, &match?(%{text: "new", kind: :added, hunk_index: 0}, &1))
      refute Map.has_key?(Map.from_struct(review), :before_lines)
    end

    test "preserves full row keys and order for deletions tied with a modification" do
      review = tied_deletion_review()

      rows = [
        {:hunk_header, {:hunk_header, 0}, "@@ -2,1 +2,0 @@ (+0, -1)", 0},
        {:context, {:baseline, 0}, "p", nil},
        {:removed, {:baseline, 1}, "A", 0},
        {:hunk_header, {:hunk_header, 1}, "@@ -3,1 +2,0 @@ (+0, -1)", 1},
        {:removed, {:baseline, 2}, "B", 1},
        {:hunk_header, {:hunk_header, 2}, "@@ -4,1 +2,1 @@ (+1, -1)", 2},
        {:removed, {:baseline, 3}, "C", 2},
        {:added, {:added, 2, 0}, "N", 2},
        {:context, {:baseline, 4}, "t", nil},
        {:context, {:baseline, 5}, "", nil}
      ]

      changed_rows = Enum.reject(rows, &match?({:context, _, _, _}, &1))

      for {context, expected} <- [{2, rows}, {0, changed_rows}] do
        actual =
          review
          |> DiffReview.to_display_lines(context)
          |> Enum.map(&{&1.kind, &1.source, &1.text, &1.hunk_index})

        assert actual == expected
      end
    end

    test "renders a deletion at EOF but fails on changed spans past EOF or overlapping" do
      eof_deletion = DiffReview.from_hunks("f.ex", "a", [hunk(:deleted, 1, 0, ["A"])])

      assert [%{kind: :hunk_header}, %{kind: :removed, text: "A"}] =
               DiffReview.to_display_lines(eof_deletion, 0)

      past_eof = DiffReview.from_hunks("f.ex", "a", [hunk(:added, 1, 1, [])])

      overlapping =
        DiffReview.from_hunks("f.ex", "a\nb", [hunk(:added, 0, 2, []), hunk(:added, 1, 1, [])])

      for review <- [past_eof, overlapping] do
        assert_raise FunctionClauseError, fn -> DiffReview.to_display_lines(review, 0) end
      end
    end
  end

  describe "matching_hunks/2" do
    test "matches clipped changed text and empty spans past EOF" do
      clipped = DiffReview.from_hunks("f.ex", "a\nb\nX", [hunk(:modified, 2, 3, ["old"])])
      exact = DiffReview.from_hunks("f.ex", "X", [hunk(:modified, 0, 1, ["old"])])
      assert DiffReview.matching_hunks(clipped, exact) == %{0 => 0}

      past_eof = DiffReview.from_hunks("f.ex", "a", [hunk(:added, 2, 3, [])])
      farther_past_eof = DiffReview.from_hunks("f.ex", "b", [hunk(:added, 6, 1, [])])
      assert DiffReview.matching_hunks(past_eof, farther_past_eof) == %{0 => 0}
    end

    test "backwards starts still match and migrate decisions in supplied order" do
      previous_hunks = [hunk(:added, 2, 1, []), hunk(:added, 0, 1, [])]

      previous =
        DiffReview.from_hunks("f.ex", "a\nb\nc", previous_hunks)
        |> DiffReview.accept_current()
        |> DiffReview.reject_current()

      hunks = [hunk(:added, 0, 1, []), hunk(:added, 1, 1, [])]
      current = DiffReview.from_hunks("f.ex", "a\nc", hunks)
      assert DiffReview.matching_hunks(previous, current) == %{0 => 1, 1 => 0}

      updated = DiffReview.update_after_lines(previous, ["a", "c"], hunks)
      assert updated.resolutions == %{0 => :rejected, 1 => :accepted}
      assert updated.current_hunk_index == 0
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

  @spec tied_deletion_review() :: DiffReview.t()
  defp tied_deletion_review do
    DiffReview.from_merge_conflicts("f.ex", [
      {:resolved, ["p"]},
      {:conflict, [], ["A"]},
      {:conflict, [], ["B"]},
      {:conflict, ["N"], ["C"]},
      {:resolved, ["t", ""]}
    ])
  end

  @spec hunk(Diff.hunk_type(), non_neg_integer(), non_neg_integer(), [String.t()]) :: Diff.hunk()
  defp hunk(type, start, count, old_lines) do
    %{
      type: type,
      start_line: start,
      count: count,
      old_start: 0,
      old_count: length(old_lines),
      old_lines: old_lines
    }
  end

  @spec assert_revert_subsets(DiffReview.t()) :: :ok
  defp assert_revert_subsets(review) do
    %{hunks: hunks, after_lines: after_lines} = review
    expected_original = Enum.reduce(Enum.reverse(hunks), after_lines, &Git.revert_hunk(&2, &1))
    assert DiffReview.original_lines(review) == expected_original

    subsets =
      Enum.reduce(hunks, [[]], fn _hunk, acc ->
        for reject? <- [false, true], decisions <- acc, do: [reject? | decisions]
      end)

    for decisions <- subsets do
      {resolved, reversed_selection} =
        hunks
        |> Enum.zip(decisions)
        |> Enum.reduce({review, []}, fn {hunk, rejected?}, {review, selected} ->
          if rejected? do
            {DiffReview.reject_current(review), [hunk | selected]}
          else
            {DiffReview.accept_current(review), selected}
          end
        end)

      expected = Enum.reduce(reversed_selection, after_lines, &Git.revert_hunk(&2, &1))
      assert DiffReview.materialized_lines(resolved) == expected
    end

    :ok
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
