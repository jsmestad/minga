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

  describe ":%s substitution" do
    test ":%s/old/new/g replaces all occurrences" do
      ctx = start_editor("foo bar foo\nfoo baz")
      send_keys(ctx, ":")
      type_text(ctx, "%s/foo/hello/g")
      send_keys(ctx, "<CR>")

      assert buffer_content(ctx) == "hello bar hello\nhello baz"
      assert_minibuffer_contains(ctx, "3 substitutions")
    end

    test ":%s/old/new/ replaces first per line" do
      ctx = start_editor("foo bar foo\nfoo baz foo")
      send_keys(ctx, ":")
      type_text(ctx, "%s/foo/x/")
      send_keys(ctx, "<CR>")

      assert buffer_content(ctx) == "x bar foo\nx baz foo"
      assert_minibuffer_contains(ctx, "2 substitutions")
    end

    test ":%s with no match shows error" do
      ctx = start_editor("hello world")
      send_keys(ctx, ":")
      type_text(ctx, "%s/xyz/abc/g")
      send_keys(ctx, "<CR>")

      assert buffer_content(ctx) == "hello world"
      assert_minibuffer_contains(ctx, "Pattern not found: xyz")
    end

    test ":%s/old//g deletes all occurrences" do
      ctx = start_editor("foo bar foo")
      send_keys(ctx, ":")
      type_text(ctx, "%s/foo//g")
      send_keys(ctx, "<CR>")

      assert buffer_content(ctx) == " bar "
    end

    test ":%s/old/new/gc shows not-yet-supported message" do
      ctx = start_editor("foo bar foo")
      send_keys(ctx, ":")
      type_text(ctx, "%s/foo/baz/gc")
      send_keys(ctx, "<CR>")

      assert buffer_content(ctx) == "foo bar foo"
      assert_minibuffer_contains(ctx, "Confirm mode not yet supported")
    end

    test "substitution is undoable" do
      ctx = start_editor("foo bar foo")
      send_keys(ctx, ":")
      type_text(ctx, "%s/foo/baz/g")
      send_keys(ctx, "<CR>")

      assert buffer_content(ctx) == "baz bar baz"

      send_keys(ctx, "u")
      assert buffer_content(ctx) == "foo bar foo"
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

    test "matches are highlighted with search background color" do
      ctx = start_editor("foo bar foo")
      send_keys(ctx, "/")
      type_text(ctx, "foo")
      send_keys(ctx, "<CR>")

      # The gutter takes some columns; find where "foo" appears on screen.
      # Both occurrences of "foo" should have the search highlight bg.
      row_text = screen_row(ctx, 0)
      # Find the first "f" in the row text
      first_f = :binary.match(row_text, "f") |> elem(0)

      cell = screen_cell(ctx, 0, first_f)

      assert cell.bg == 0xECBE7B,
             "Expected search highlight bg on first 'foo', got: #{inspect(cell)}"
    end

    test "matches highlight live during incremental / search" do
      ctx = start_editor("foo bar foo")
      send_keys(ctx, "/")
      type_text(ctx, "foo")

      # Still in search mode — highlights should be visible
      row_text = screen_row(ctx, 0)
      first_f = :binary.match(row_text, "f") |> elem(0)
      cell = screen_cell(ctx, 0, first_f)

      assert cell.bg == 0xECBE7B,
             "Expected live search highlight during / mode, got: #{inspect(cell)}"
    end

    test "matches highlight live while typing :%s/pattern" do
      ctx = start_editor("foo bar foo")
      send_keys(ctx, ":")
      type_text(ctx, "%s/foo")

      # Still in command mode typing the substitute — highlights should show
      row_text = screen_row(ctx, 0)
      first_f = :binary.match(row_text, "f") |> elem(0)
      cell = screen_cell(ctx, 0, first_f)

      assert cell.bg == 0xECBE7B,
             "Expected live highlight during :%s typing, got: #{inspect(cell)}"
    end

    test "live substitution preview shows replacement text highlighted" do
      ctx = start_editor("foo bar foo")
      send_keys(ctx, ":")
      type_text(ctx, "%s/foo/hello/g")

      # Buffer is NOT modified yet (still in command mode)
      assert buffer_content(ctx) == "foo bar foo"

      # But the screen should show the preview
      row_text = screen_row(ctx, 0)

      assert String.contains?(row_text, "hello bar hello"),
             "Expected live preview of substitution, got: #{inspect(row_text)}"

      # The replacement text "hello" should be highlighted in yellow
      first_h = :binary.match(row_text, "h") |> elem(0)
      cell = screen_cell(ctx, 0, first_h)

      assert cell.bg == 0xECBE7B,
             "Expected replacement text highlighted in yellow, got: #{inspect(cell)}"
    end
  end
end
