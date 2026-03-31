defmodule MingaEditor.Agent.View.PreviewTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.DiffReview
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
  end

  describe "file content" do
    test "set_file transitions to file state" do
      p = Preview.new() |> Preview.set_file("lib/foo.ex", "defmodule Foo do\nend")
      assert {:file, "lib/foo.ex", "defmodule Foo do\nend"} = p.content
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
end
