defmodule Minga.Buffer.VirtualTextTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Decorations.VirtualText
  alias Minga.Face

  # ── CRUD ─────────────────────────────────────────────────────────────────

  describe "add_virtual_text/3" do
    test "adds an EOL virtual text and returns its ID" do
      decs = Decorations.new()

      {id, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"← error", Minga.Face.new(fg: 0xFF6C6B)}],
          placement: :eol
        )

      assert is_reference(id)
      assert Decorations.has_virtual_texts?(decs)
    end

    test "adds inline virtual text" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_virtual_text(decs, {3, 10},
          segments: [{"ghost text", Minga.Face.new(fg: 0x555555, italic: true)}],
          placement: :inline
        )

      vts = Decorations.inline_virtual_texts_for_line(decs, 3)
      assert length(vts) == 1
      assert hd(vts).placement == :inline
      assert hd(vts).anchor == {3, 10}
    end

    test "adds virtual lines above and below" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"▎ Agent", Minga.Face.new(fg: 0x51AFEF, bold: true)}],
          placement: :above
        )

      {_id, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"───────", Minga.Face.new(fg: 0x555555)}],
          placement: :below
        )

      {above, below} = Decorations.virtual_lines_for_line(decs, 5)
      assert length(above) == 1
      assert length(below) == 1
    end

    test "increments version" do
      decs = Decorations.new()
      assert decs.version == 0

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 0},
          segments: [{"x", Minga.Face.new()}],
          placement: :eol
        )

      assert decs.version == 1
    end
  end

  describe "remove_virtual_text/2" do
    test "removes by ID" do
      decs = Decorations.new()

      {id, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"text", Minga.Face.new()}],
          placement: :eol
        )

      decs = Decorations.remove_virtual_text(decs, id)
      refute Decorations.has_virtual_texts?(decs)
    end

    test "no-op for non-existent ID" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"text", Minga.Face.new()}],
          placement: :eol
        )

      decs2 = Decorations.remove_virtual_text(decs, make_ref())
      assert Decorations.has_virtual_texts?(decs2)
      assert decs2.version == decs.version
    end
  end

  # ── Queries ──────────────────────────────────────────────────────────────

  describe "virtual_texts_for_line/2" do
    test "returns only texts anchored to the given line" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {3, 0},
          segments: [{"line 3", Minga.Face.new()}],
          placement: :eol
        )

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"line 5", Minga.Face.new()}],
          placement: :eol
        )

      {_, decs} =
        Decorations.add_virtual_text(decs, {3, 10},
          segments: [{"also line 3", Minga.Face.new()}],
          placement: :inline
        )

      assert length(Decorations.virtual_texts_for_line(decs, 3)) == 2
      assert length(Decorations.virtual_texts_for_line(decs, 5)) == 1
      assert Decorations.virtual_texts_for_line(decs, 7) == []
    end

    test "sorts by column then priority" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 20},
          segments: [{"b", Minga.Face.new()}],
          placement: :inline,
          priority: 5
        )

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 10},
          segments: [{"a", Minga.Face.new()}],
          placement: :inline,
          priority: 10
        )

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 10},
          segments: [{"a2", Minga.Face.new()}],
          placement: :inline,
          priority: 1
        )

      vts = Decorations.virtual_texts_for_line(decs, 0)
      anchors = Enum.map(vts, fn vt -> {elem(vt.anchor, 1), vt.priority} end)
      assert anchors == [{10, 1}, {10, 10}, {20, 5}]
    end
  end

  describe "virtual_line_count/3" do
    test "counts above/below virtual lines in range" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"header", Minga.Face.new()}],
          placement: :above
        )

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"separator", Minga.Face.new()}],
          placement: :below
        )

      {_, decs} =
        Decorations.add_virtual_text(decs, {10, 0},
          segments: [{"another header", Minga.Face.new()}],
          placement: :above
        )

      # EOL doesn't count as a virtual line
      {_, decs} =
        Decorations.add_virtual_text(decs, {7, 0},
          segments: [{"eol text", Minga.Face.new()}],
          placement: :eol
        )

      assert Decorations.virtual_line_count(decs, 0, 20) == 3
      assert Decorations.virtual_line_count(decs, 5, 5) == 2
      assert Decorations.virtual_line_count(decs, 6, 9) == 0
      assert Decorations.virtual_line_count(decs, 10, 10) == 1
    end

    test "empty decorations returns 0" do
      decs = Decorations.new()
      assert Decorations.virtual_line_count(decs, 0, 100) == 0
    end
  end

  # ── Column mapping ──────────────────────────────────────────────────────

  describe "buf_col_to_display_col/3" do
    test "no virtual text returns buf_col unchanged" do
      decs = Decorations.new()
      assert Decorations.buf_col_to_display_col(decs, 0, 10) == 10
    end

    test "inline virtual text before buf_col shifts it right" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 5},
          segments: [{"GHOST", Minga.Face.new()}],
          placement: :inline
        )

      # "GHOST" is 5 chars at col 5. Buffer col 10 becomes display col 15.
      assert Decorations.buf_col_to_display_col(decs, 0, 10) == 15
      # Buffer col 5 (at the anchor): virtual text is "at or before", so shifted
      assert Decorations.buf_col_to_display_col(decs, 0, 5) == 10
      # Buffer col 3 (before virtual text): no shift
      assert Decorations.buf_col_to_display_col(decs, 0, 3) == 3
    end

    test "multiple inline virtual texts accumulate" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 5},
          segments: [{"AAA", Minga.Face.new()}],
          placement: :inline
        )

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 10},
          segments: [{"BB", Minga.Face.new()}],
          placement: :inline
        )

      # Buffer col 15: both virtual texts are before it
      # AAA (3 chars at col 5) + BB (2 chars at col 10) = 5 extra
      assert Decorations.buf_col_to_display_col(decs, 0, 15) == 20
      # Buffer col 7: only AAA is before it
      assert Decorations.buf_col_to_display_col(decs, 0, 7) == 10
    end

    test "EOL virtual text does not affect column mapping" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 0},
          segments: [{"eol stuff", Minga.Face.new()}],
          placement: :eol
        )

      assert Decorations.buf_col_to_display_col(decs, 0, 10) == 10
    end
  end

  describe "display_col_to_buf_col/3" do
    test "no virtual text returns display_col unchanged" do
      decs = Decorations.new()
      assert Decorations.display_col_to_buf_col(decs, 0, 10) == 10
    end

    test "click past inline virtual text maps to correct buffer col" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 5},
          segments: [{"GHOST", Minga.Face.new()}],
          placement: :inline
        )

      # Display col 15 is buffer col 10 (subtract 5 chars of virtual text)
      assert Decorations.display_col_to_buf_col(decs, 0, 15) == 10
      # Display col 3 (before virtual text): maps directly
      assert Decorations.display_col_to_buf_col(decs, 0, 3) == 3
    end

    test "click ON virtual text snaps to anchor column" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 5},
          segments: [{"GHOST", Minga.Face.new()}],
          placement: :inline
        )

      # Display cols 5-9 are the virtual text itself. Clicking there
      # should snap to the anchor column (5).
      assert Decorations.display_col_to_buf_col(decs, 0, 5) == 5
      assert Decorations.display_col_to_buf_col(decs, 0, 7) == 5
      assert Decorations.display_col_to_buf_col(decs, 0, 9) == 5
    end
  end

  # ── Anchor adjustment ───────────────────────────────────────────────────

  describe "anchor adjustment for virtual text" do
    test "insertion before anchor shifts it right" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 10},
          segments: [{"text", Minga.Face.new()}],
          placement: :eol
        )

      decs = Decorations.adjust_for_edit(decs, {3, 0}, {3, 0}, {5, 0})
      vts = Decorations.virtual_texts_for_line(decs, 7)
      assert length(vts) == 1
      assert hd(vts).anchor == {7, 10}
    end

    test "insertion at same line before column shifts column" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 10},
          segments: [{"text", Minga.Face.new()}],
          placement: :inline
        )

      # Insert 5 chars at col 3 on line 5
      decs = Decorations.adjust_for_edit(decs, {5, 3}, {5, 3}, {5, 8})
      vts = Decorations.inline_virtual_texts_for_line(decs, 5)
      assert length(vts) == 1
      assert hd(vts).anchor == {5, 15}
    end

    test "deletion spanning anchor moves it to edit start" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 10},
          segments: [{"text", Minga.Face.new()}],
          placement: :eol
        )

      # Delete lines 3-7
      decs = Decorations.adjust_for_edit(decs, {3, 0}, {8, 0}, {3, 0})
      vts = Decorations.virtual_texts_for_line(decs, 3)
      assert length(vts) == 1
      assert hd(vts).anchor == {3, 0}
    end

    test "edit after anchor leaves it unchanged" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 10},
          segments: [{"text", Minga.Face.new()}],
          placement: :eol
        )

      decs = Decorations.adjust_for_edit(decs, {10, 0}, {10, 0}, {11, 0})
      vts = Decorations.virtual_texts_for_line(decs, 5)
      assert length(vts) == 1
      assert hd(vts).anchor == {5, 10}
    end
  end

  # ── VirtualText struct ──────────────────────────────────────────────────

  describe "VirtualText.display_width/1" do
    test "computes total width of segments" do
      vt = %VirtualText{
        id: make_ref(),
        anchor: {0, 0},
        segments: [{"hello", Minga.Face.new()}, {" world", Minga.Face.new()}],
        placement: :inline
      }

      assert VirtualText.display_width(vt) == 11
    end

    test "empty segments have zero width" do
      vt = %VirtualText{
        id: make_ref(),
        anchor: {0, 0},
        segments: [],
        placement: :eol
      }

      assert VirtualText.display_width(vt) == 0
    end
  end

  # ── Integration with empty? ─────────────────────────────────────────────

  describe "empty?/1 with virtual text" do
    test "empty when no highlights and no virtual texts" do
      assert Decorations.empty?(Decorations.new())
    end

    test "not empty with only virtual texts" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 0},
          segments: [{"x", Minga.Face.new()}],
          placement: :eol
        )

      refute Decorations.empty?(decs)
    end

    test "clear removes virtual texts too" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {0, 0},
          segments: [{"x", Minga.Face.new()}],
          placement: :eol
        )

      decs = Decorations.clear(decs)
      assert Decorations.empty?(decs)
    end
  end
end
