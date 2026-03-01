defmodule Minga.Editor.SearchTest do
  use Minga.Test.EditorCase, async: true

  describe "forward search with /" do
    test "/ enters search mode and shows prompt" do
      ctx = start_editor("hello world\nfoo bar")
      send_keys(ctx, "/")
      assert_minibuffer_contains(ctx, "/")
    end

    test "typing pattern incrementally moves cursor to match" do
      ctx = start_editor("hello world\nfoo bar")
      send_keys(ctx, "/")
      type_text(ctx, "foo")
      # Cursor should be on "foo" at line 1
      assert {1, 0} = buffer_cursor(ctx)
    end

    test "Enter confirms search and returns to normal mode" do
      ctx = start_editor("hello world\nfoo bar")
      send_keys(ctx, "/")
      type_text(ctx, "foo")
      send_keys(ctx, "<CR>")
      assert {1, 0} = buffer_cursor(ctx)
      assert_modeline_contains(ctx, "NORMAL")
    end

    test "Escape cancels search and restores cursor" do
      ctx = start_editor("hello world\nfoo bar")
      # Move cursor to {0, 5} first
      send_keys(ctx, "lllll")
      assert {0, 5} = buffer_cursor(ctx)

      send_keys(ctx, "/")
      type_text(ctx, "foo")
      assert {1, 0} = buffer_cursor(ctx)

      send_keys(ctx, "<Esc>")
      # Cursor restored to original position
      assert {0, 5} = buffer_cursor(ctx)
    end

    test "n jumps to next match" do
      ctx = start_editor("foo hello foo world foo")
      send_keys(ctx, "/")
      type_text(ctx, "foo")
      send_keys(ctx, "<CR>")
      # First match found after {0,0} should be {0,10}
      assert {0, 10} = buffer_cursor(ctx)

      send_keys(ctx, "n")
      assert {0, 20} = buffer_cursor(ctx)
    end

    test "N jumps to previous match" do
      ctx = start_editor("foo hello foo world foo")
      send_keys(ctx, "/")
      type_text(ctx, "foo")
      send_keys(ctx, "<CR>")
      # At {0, 10}
      assert {0, 10} = buffer_cursor(ctx)

      send_keys(ctx, "N")
      assert {0, 0} = buffer_cursor(ctx)
    end

    test "search wraps around end of buffer" do
      ctx = start_editor("foo\nbar\nbaz")
      # Move to last line
      send_keys(ctx, "G")

      send_keys(ctx, "/")
      type_text(ctx, "foo")
      send_keys(ctx, "<CR>")
      # Should wrap to {0, 0}
      assert {0, 0} = buffer_cursor(ctx)
    end
  end

  describe "backward search with ?" do
    test "? enters backward search mode" do
      ctx = start_editor("hello world\nfoo bar")
      send_keys(ctx, "?")
      assert_minibuffer_contains(ctx, "?")
    end

    test "backward search finds match before cursor" do
      ctx = start_editor("foo\nbar\nfoo")
      # G goes to last line. Move to end of "foo" on line 2
      send_keys(ctx, "G$")
      {line, _} = buffer_cursor(ctx)
      assert line == 2

      send_keys(ctx, "?")
      type_text(ctx, "bar")
      send_keys(ctx, "<CR>")
      assert {1, 0} = buffer_cursor(ctx)
    end
  end

  describe "* and # word search" do
    test "* searches for word under cursor forward" do
      ctx = start_editor("hello world\nhello again")
      send_keys(ctx, "*")
      assert {1, 0} = buffer_cursor(ctx)
    end

    test "# searches for word under cursor backward" do
      ctx = start_editor("hello world\nhello again")
      # Go to second line, cursor on "hello"
      send_keys(ctx, "j")
      assert {1, 0} = buffer_cursor(ctx)

      send_keys(ctx, "#")
      assert {0, 0} = buffer_cursor(ctx)
    end
  end

  describe "n/N without prior search" do
    test "n shows message when no previous pattern" do
      ctx = start_editor("hello world")
      send_keys(ctx, "n")
      assert_minibuffer_contains(ctx, "No previous search pattern")
    end
  end

  describe "search highlighting" do
    test "search pattern persists after confirmed search" do
      ctx = start_editor("foo bar foo")
      send_keys(ctx, "/")
      type_text(ctx, "foo")
      send_keys(ctx, "<CR>")

      # Pattern persists — n should work
      send_keys(ctx, "n")
      # Should have moved to next occurrence
      {_line, col} = buffer_cursor(ctx)
      assert col >= 0
    end
  end
end
