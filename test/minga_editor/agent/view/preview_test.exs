defmodule MingaEditor.Agent.View.PreviewTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.View.Preview

  describe "new/0" do
    test "starts empty with auto-follow engaged" do
      p = Preview.new()
      assert p.content == :empty
      assert p.scroll.offset == 0
      assert p.scroll.pinned == true
    end
  end

  describe "shell content" do
    test "set_shell transitions to running shell state" do
      p = Preview.new() |> Preview.set_shell("mix test")
      assert {:shell, "mix test", "", :running} = p.content
      assert p.scroll.offset == 0
      assert p.scroll.pinned == true
    end

    test "update_shell_output appends output while running" do
      p = Preview.new() |> Preview.set_shell("ls")
      p = Preview.update_shell_output(p, "file1.ex\nfile2.ex")
      assert {:shell, "ls", "file1.ex\nfile2.ex", :running} = p.content
    end

    test "update_shell_output no-ops when not in shell running state" do
      p = Preview.new()
      assert p == Preview.update_shell_output(p, "ignored")
    end

    test "finish_shell marks command as done" do
      p = Preview.new() |> Preview.set_shell("mix test")
      p = Preview.finish_shell(p, "3 tests, 0 failures", :done)
      assert {:shell, "mix test", "3 tests, 0 failures", :done} = p.content
    end

    test "finish_shell marks command as error" do
      p = Preview.new() |> Preview.set_shell("false")
      p = Preview.finish_shell(p, "exit code 1", :error)
      assert {:shell, "false", "exit code 1", :error} = p.content
    end

    test "auto-follow stays engaged on shell output update" do
      p = Preview.new() |> Preview.set_shell("tail -f log")
      p = Preview.update_shell_output(p, "line 1\nline 2\nline 3")
      # auto_follow true means the renderer pins to bottom; no sentinel
      assert p.scroll.pinned
      assert p.scroll.offset == 0
    end

    test "auto-follow pauses when user scrolls manually" do
      p = Preview.new() |> Preview.set_shell("tail -f log")
      p = Preview.scroll_up(p, 5)
      refute p.scroll.pinned

      # New output does not re-engage auto-follow
      p = Preview.update_shell_output(p, "new output")
      refute p.scroll.pinned
    end
  end

  describe "diff content" do
    test "set_diff transitions to diff state" do
      review = DiffReview.new("test.ex", "old\n", "new\n")
      p = Preview.new() |> Preview.set_diff(review)
      assert {:diff, ^review} = p.content
    end

    test "update_diff modifies the review" do
      review = DiffReview.new("test.ex", "line1\nold\nline3\n", "line1\nnew\nline3\n")
      p = Preview.new() |> Preview.set_diff(review)
      p = Preview.update_diff(p, &DiffReview.accept_current/1)
      {:diff, updated} = p.content
      assert DiffReview.resolved?(updated)
    end

    test "diff_review returns the review when in diff mode" do
      review = DiffReview.new("test.ex", "old\n", "new\n")
      p = Preview.new() |> Preview.set_diff(review)
      assert Preview.diff_review(p) == review
    end

    test "diff_review returns nil when not in diff mode" do
      p = Preview.new()
      assert Preview.diff_review(p) == nil
    end

    test "replace_diff preserves scroll while a diff remains and clears for nil" do
      review = DiffReview.new("test.ex", "old\n", "new\n")
      next_review = DiffReview.new("test.ex", "old\n", "newer\n")

      p = Preview.new() |> Preview.set_diff(review) |> Preview.scroll_down(4)
      p = Preview.replace_diff(p, next_review)

      assert {:diff, ^next_review} = p.content
      assert p.scroll.offset == 4

      p = Preview.replace_diff(p, nil)
      assert p.content == :empty
      assert p.scroll.offset == 0
    end

    test "hunk navigation changes the actionable hunk without retiring rows or selection" do
      before = Enum.map_join(1..12, "\n", &"line #{&1}")

      after_content =
        before |> String.replace("line 1\n", "first\n") |> String.replace("line 12", "last")

      review = DiffReview.new("selected.ex", before, after_content)
      selected = Preview.new() |> Preview.set_diff(review) |> Preview.scroll_down(4)

      for direction <- [:next, :previous] do
        navigated = Preview.navigate_hunk(selected, direction)
        assert Preview.diff_review(navigated).current_hunk_index == 1
        assert navigated.rows_revision == selected.rows_revision
        assert navigated.selection_revision == selected.selection_revision
        assert navigated.content_revision > selected.content_revision
        assert navigated.scroll == selected.scroll
        assert Preview.diff_review(navigated).hunks == review.hunks
        assert Preview.diff_review(navigated).after_lines == review.after_lines
      end
    end

    test "hunk navigation leaves every non-actionable preview tag unchanged" do
      stale =
        Preview.new()
        |> Preview.set_diff(DiffReview.new("selected.ex", "before", "after"))
        |> Preview.refresh_after_write("selected.ex", "later", EditTimeline.new())

      previews = [
        Preview.new(),
        Preview.set_shell(Preview.new(), "mix test"),
        Preview.new() |> Preview.set_shell("mix test") |> Preview.finish_shell("passed", :done),
        Preview.new() |> Preview.set_shell("mix test") |> Preview.finish_shell("failed", :error),
        Preview.set_file(Preview.new(), "selected.ex", "contents"),
        Preview.set_directory(Preview.new(), "lib", ["selected.ex"]),
        stale
      ]

      for preview <- previews, direction <- [:next, :previous] do
        assert Preview.navigate_hunk(preview, direction) == preview
      end
    end

    test "refreshing the selected file advances rows but changing files also retires selection" do
      first = Preview.new() |> Preview.set_diff(DiffReview.new("a.ex", "before", "first"))
      refreshed = Preview.set_diff(first, DiffReview.new("a.ex", "before", "second"))
      other = Preview.set_diff(refreshed, DiffReview.new("b.ex", "before", "after"))

      assert refreshed.rows_revision > first.rows_revision
      assert refreshed.selection_revision == first.selection_revision
      assert other.rows_revision > refreshed.rows_revision
      assert other.selection_revision > refreshed.selection_revision
    end
  end

  describe "file content" do
    test "set_file transitions to file state" do
      p = Preview.new() |> Preview.set_file("lib/foo.ex", "defmodule Foo do\nend")
      assert {:file, "lib/foo.ex", "defmodule Foo do\nend"} = p.content
    end
  end

  describe "background file changes" do
    test "unrelated writes leave every preview kind and reading position unchanged" do
      review = DiffReview.new("selected.ex", "old\n", "new\n")

      previews = [
        Preview.new(),
        Preview.new() |> Preview.set_shell("mix test"),
        Preview.new() |> Preview.set_shell("mix test") |> Preview.finish_shell("passed", :done),
        Preview.new() |> Preview.set_shell("mix test") |> Preview.finish_shell("failed", :error),
        Preview.new() |> Preview.set_diff(review),
        Preview.new() |> Preview.set_file("selected.ex", "new\n"),
        Preview.new() |> Preview.set_directory("lib", ["selected.ex"]),
        Preview.new()
        |> Preview.set_diff(review)
        |> Preview.refresh_after_write("selected.ex", "later\n", EditTimeline.new()),
        Preview.new()
        |> Preview.set_file("selected.ex", "new\n")
        |> Preview.refresh_after_write("selected.ex", "later\n", EditTimeline.new())
      ]

      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("other.ex", "write-b", "edit", "before", "after")

      for preview <- previews do
        selected = Preview.scroll_down(preview, 4)
        assert Preview.refresh_after_write(selected, "other.ex", "after", timeline) == selected
      end
    end

    test "a selected revision retains its exact reading presentation and disables stale decisions" do
      review = DiffReview.new("selected.ex", "old\n", "first\n") |> DiffReview.accept_all()
      selected = Preview.new() |> Preview.set_diff(review) |> Preview.scroll_down(4)

      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("selected.ex", "write-a", "edit", "old\n", "second\n")

      refreshed = Preview.refresh_after_write(selected, "selected.ex", "second\n", timeline)

      assert refreshed.content == selected.content
      assert refreshed.scroll == selected.scroll
      assert refreshed.freshness == :stale
      assert Preview.diff_review(refreshed) == nil
      assert Preview.update_diff(refreshed, &DiffReview.reject_all/1) == refreshed

      current =
        DiffReview.from_hunks(
          "selected.ex",
          "second\n",
          EditTimeline.cumulative_hunks(timeline, "selected.ex")
        )

      reviewed = Preview.set_diff(refreshed, current)
      assert DiffReview.materialized_lines(Preview.diff_review(reviewed)) == ["second", ""]
      assert reviewed.freshness == :current
      refute DiffReview.resolved?(Preview.diff_review(reviewed))
    end

    test "a write back to baseline retains the reading revision but makes its old decisions unavailable" do
      review = DiffReview.new("selected.ex", "old\n", "first\n") |> DiffReview.accept_all()
      selected = Preview.new() |> Preview.set_diff(review) |> Preview.scroll_down(4)

      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("selected.ex", "revert-a", "edit", "old\n", "old\n")

      refreshed = Preview.refresh_after_write(selected, "selected.ex", "old\n", timeline)

      assert refreshed.content == selected.content
      assert refreshed.scroll == selected.scroll
      assert Preview.selected_path(refreshed) == "selected.ex"
      assert refreshed.freshness == :stale
      assert Preview.diff_review(refreshed) == nil
      assert EditTimeline.cumulative_hunks(timeline, "selected.ex") == []
    end

    test "a selected plain file keeps its exact bytes and anchor until an explicit refresh" do
      selected =
        Preview.new() |> Preview.set_file("selected.ex", "old\n") |> Preview.scroll_down(4)

      refreshed =
        Preview.refresh_after_write(selected, "selected.ex", "new\n", EditTimeline.new())

      assert refreshed.content == selected.content
      assert refreshed.scroll == selected.scroll
      assert refreshed.freshness == :stale

      reviewed = Preview.set_file(refreshed, "selected.ex", "new\n")
      assert reviewed.content == {:file, "selected.ex", "new\n"}
      assert reviewed.freshness == :current
    end
  end

  describe "scrolling" do
    test "scroll_down increases offset and disengages auto-follow" do
      p = Preview.new() |> Preview.scroll_down(5)
      assert p.scroll.offset == 5
      assert p.scroll.pinned == false
    end

    test "scroll_up decreases offset, clamped at 0" do
      p = %{Preview.new() | scroll: Minga.Editing.Scroll.new(3)}
      p = Preview.scroll_up(p, 10)
      assert p.scroll.offset == 0
      assert p.scroll.pinned == false
    end

    test "scroll_to_top resets to 0" do
      p = %{Preview.new() | scroll: Minga.Editing.Scroll.new(50)}
      p = Preview.scroll_to_top(p)
      assert p.scroll.offset == 0
    end

    test "scroll_to_bottom re-engages auto-follow without changing offset" do
      p = Preview.new() |> Preview.scroll_down(5)
      refute p.scroll.pinned
      p = Preview.scroll_to_bottom(p)
      # offset stays at 5; renderer resolves "bottom"
      assert p.scroll.offset == 5
      assert p.scroll.pinned
    end
  end

  describe "queries" do
    test "empty? returns true for empty preview" do
      assert Preview.empty?(Preview.new())
    end

    test "empty? returns false for shell preview" do
      p = Preview.new() |> Preview.set_shell("ls")
      refute Preview.empty?(p)
    end

    test "shell? returns true for shell preview" do
      p = Preview.new() |> Preview.set_shell("ls")
      assert Preview.shell?(p)
    end

    test "diff? returns true for diff preview" do
      review = DiffReview.new("f.ex", "a\n", "b\n")
      p = Preview.new() |> Preview.set_diff(review)
      assert Preview.diff?(p)
    end
  end

  describe "clear/1" do
    test "resets to empty state" do
      p = Preview.new() |> Preview.set_shell("ls") |> Preview.scroll_down(10)
      p = Preview.clear(p)
      assert p.content == :empty
      assert p.scroll.offset == 0
      assert p.scroll.pinned == true
    end
  end

  describe "directory content" do
    test "set_directory transitions to directory state" do
      p = Preview.new() |> Preview.set_directory("lib/", ["foo.ex", "bar/"])
      assert {:directory, "lib/", ["foo.ex", "bar/"]} = p.content
    end

    test "directory? returns true for directory preview" do
      p = Preview.new() |> Preview.set_directory(".", ["a.ex"])
      assert Preview.directory?(p)
    end

    test "directory? returns false for other content" do
      refute Preview.directory?(Preview.new())
    end
  end

  describe "transitions" do
    test "shell -> diff transition works" do
      p = Preview.new() |> Preview.set_shell("mix test")
      review = DiffReview.new("f.ex", "a\n", "b\n")
      p = Preview.set_diff(p, review)
      assert Preview.diff?(p)
      refute Preview.shell?(p)
    end

    test "diff -> shell transition works" do
      review = DiffReview.new("f.ex", "a\n", "b\n")
      p = Preview.new() |> Preview.set_diff(review)
      p = Preview.set_shell(p, "git status")
      assert Preview.shell?(p)
      refute Preview.diff?(p)
    end
  end

  test "matching review observations change fit without replacing current or frozen reading intent" do
    review = DiffReview.new("selected.ex", "before", "after")
    selected = Preview.set_diff(Preview.new(), review)
    source = Preview.review_source(selected)
    {:ok, selected} = Preview.observe_review(selected, source, 100, 8)
    selected = Preview.scroll_down(selected, 12)
    stale = Preview.refresh_after_write(selected, "selected.ex", "newer", EditTimeline.new())

    for preview <- [selected, stale] do
      assert {:ok, observed} = Preview.observe_review(preview, source, 100, 20)
      assert observed.scroll.metrics == %{total_lines: 100, visible_height: 20}
      assert observed.scroll.offset == preview.scroll.offset
      assert observed.scroll.pinned == preview.scroll.pinned
      assert %{observed | scroll: preview.scroll} == preview
    end

    assert Preview.diff_review(stale) == nil
  end

  test "review geometry cannot cross a source revision, selection, or preview kind" do
    review = DiffReview.new("selected.ex", "before", "after")
    selected = Preview.set_diff(Preview.new(), review)
    source = Preview.review_source(selected)

    replacements = [
      Preview.new(),
      Preview.set_shell(selected, "mix test"),
      Preview.set_file(selected, "selected.ex", "after"),
      Preview.set_directory(selected, ".", []),
      Preview.set_diff(selected, review),
      Preview.set_diff(selected, DiffReview.new("other.ex", "before", "after")),
      selected |> Preview.clear() |> Preview.set_diff(review)
    ]

    for replacement <- replacements do
      assert :stale = Preview.observe_review(replacement, source, 100, 20)
    end
  end
end
