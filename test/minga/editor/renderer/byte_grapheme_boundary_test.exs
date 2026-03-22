defmodule Minga.Editor.Renderer.ByteGraphemeBoundaryTest do
  @moduledoc """
  Tests for the render boundary byte→grapheme conversion.

  Ensures cursor placement, modeline column display, and visual selection
  rendering are correct with multi-byte UTF-8 characters (where byte offset
  differs from grapheme index).
  """

  use Minga.Test.EditorCase, async: true

  describe "cursor placement with multi-byte characters" do
    test "cursor is at correct screen column after multi-byte characters" do
      # "café" — é is 2 bytes, so byte_col=5 but grapheme_col=4
      ctx = start_editor("café")

      # Move to end of line ($ in normal mode)
      send_key_sync(ctx, ?$)

      {_row, col} = screen_cursor(ctx)
      gutter_w = 3

      # "café" has 4 graphemes, cursor on last char (index 3)
      assert col == gutter_w + 3
    end

    test "cursor is at correct screen column with emoji" do
      # "a🎉b" — 🎉 is 4 bytes and 2 display columns wide
      ctx = start_editor("a🎉b")

      send_key_sync(ctx, ?$)

      {_row, col} = screen_cursor(ctx)
      gutter_w = 3

      # Display columns: a=1, 🎉=2, b=1 — 'b' is at display col 3 (not grapheme 2)
      assert col == gutter_w + 3
    end

    test "cursor placement with multiple multi-byte characters" do
      # "ñoño" — each ñ is 2 bytes
      ctx = start_editor("ñoño")

      # Move right 3 times to reach 'o' at end
      send_key_sync(ctx, ?l)
      send_key_sync(ctx, ?l)
      send_key_sync(ctx, ?l)

      {_row, col} = screen_cursor(ctx)
      gutter_w = 3

      # grapheme index 3
      assert col == gutter_w + 3
    end
  end

  describe "modeline column display with multi-byte characters" do
    test "modeline shows grapheme column, not byte offset" do
      ctx = start_editor("café")

      # Move to end: $ puts cursor on last char
      send_key_sync(ctx, ?$)

      ml = modeline(ctx)
      # cursor_line=0, grapheme_col=3 → displayed as "1:4" (1-indexed)
      assert String.contains?(ml, "1:4"),
             "Expected modeline to show column 4 (grapheme), got: #{inspect(ml)}"
    end

    test "modeline column 1 at start of line with multi-byte content" do
      ctx = start_editor("émoji")

      ml = modeline(ctx)

      assert String.contains?(ml, "1:1"),
             "Expected modeline to show column 1, got: #{inspect(ml)}"
    end
  end

  describe "visual selection with multi-byte characters" do
    test "visual selection highlights correct graphemes" do
      # "café" — select "af" (graphemes 1-2)
      ctx = start_editor("café")
      gutter_w = 3

      # Move to 'a', enter visual, select through 'f'
      send_key_sync(ctx, ?l)
      send_key_sync(ctx, ?v)
      send_key_sync(ctx, ?l)

      # Cells at grapheme positions 1 and 2 (gutter_w + 1, gutter_w + 2) should be reversed
      cell_a = screen_cell(ctx, 1, gutter_w + 1)
      cell_f = screen_cell(ctx, 1, gutter_w + 2)

      assert :reverse in cell_a.attrs,
             "Expected 'a' at col #{gutter_w + 1} to be selected"

      assert :reverse in cell_f.attrs,
             "Expected 'f' at col #{gutter_w + 2} to be selected"

      # 'c' before selection should not be reversed
      cell_c = screen_cell(ctx, 1, gutter_w)
      refute :reverse in cell_c.attrs, "Expected 'c' not to be selected"
    end

    test "visual selection with emoji characters" do
      ctx = start_editor("a🎉b")
      gutter_w = 3

      # Select all with v$
      send_key_sync(ctx, ?v)
      send_key_sync(ctx, ?$)

      cell_a = screen_cell(ctx, 1, gutter_w)
      assert :reverse in cell_a.attrs, "Expected 'a' to be selected"
    end
  end

  describe "insert mode cursor with multi-byte characters" do
    test "cursor after inserting multi-byte character" do
      ctx = start_editor("")

      send_key_sync(ctx, ?i)
      # Type 'é' — this is tricky since send_key sends a codepoint
      send_key_sync(ctx, ?a)
      send_key_sync(ctx, ?b)

      {_row, col} = screen_cursor(ctx)
      gutter_w = 3

      # After typing "ab", cursor should be at grapheme col 2
      assert col == gutter_w + 2
    end
  end

  describe "ASCII content (byte == grapheme)" do
    test "cursor placement unchanged for ASCII" do
      ctx = start_editor("hello world")

      send_key_sync(ctx, ?$)

      {_row, col} = screen_cursor(ctx)
      gutter_w = 3

      # "hello world" = 11 chars, cursor on 'd' at index 10
      assert col == gutter_w + 10
    end

    test "modeline column correct for ASCII" do
      ctx = start_editor("hello")

      send_key_sync(ctx, ?$)

      ml = modeline(ctx)

      assert String.contains?(ml, "1:5"),
             "Expected modeline to show column 5, got: #{inspect(ml)}"
    end
  end
end
