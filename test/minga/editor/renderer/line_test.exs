defmodule Minga.Editor.Renderer.LineTest do
  @moduledoc """
  Tests for line content rendering: file content, unicode, insert mode,
  visual selection, scrolling, and tilde rows.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Test.HeadlessPort

  # Content starts at row 1 because the tab bar occupies row 0.
  @content_row 1

  describe "file content rendering" do
    test "opens a file and renders its content on screen" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      assert_row_contains(ctx, @content_row, "hello world")
      assert_row_contains(ctx, @content_row + 1, "second line")
      assert_row_contains(ctx, @content_row + 2, "third line")
    end

    test "empty lines below content show tildes" do
      ctx = start_editor("just one line", height: 10)

      assert_row_contains(ctx, @content_row, "just one line")
      assert_row_contains(ctx, @content_row + 1, "~")
    end

    test "renders unicode content correctly" do
      ctx = start_editor("héllo wörld 🎉\nñoño")

      assert_row_contains(ctx, @content_row, "héllo wörld")
      assert_row_contains(ctx, @content_row + 1, "ñoño")
    end
  end

  describe "insert mode rendering" do
    test "typed characters appear on screen" do
      ctx = start_editor("hello")

      send_key_sync(ctx, ?i)
      send_key_sync(ctx, ?X)
      send_key_sync(ctx, ?Y)

      assert_row_contains(ctx, @content_row, "XYhello")
    end

    test "newline in insert mode creates a new line on screen" do
      ctx = start_editor("hello")

      send_key_sync(ctx, ?i)
      send_key_sync(ctx, 13)

      assert_row_contains(ctx, @content_row + 1, "hello")
    end
  end

  describe "wide character (CJK / emoji) rendering" do
    test "CJK characters render without overlap or gaps" do
      ctx = start_editor("你好世界")

      assert_row_contains(ctx, @content_row, "你好世界")
    end

    test "cursor on CJK character lands at correct display column" do
      ctx = start_editor("你好")

      # Move right once - cursor steps to second CJK char (display col 2)
      send_key_sync(ctx, ?l)

      screen = HeadlessPort.get_screen(ctx.port)
      {cursor_row, cursor_col} = screen.cursor

      assert cursor_row == @content_row
      # Gutter width for 1-line file is 5 (2 sign + 2 digits + 1 space);
      # '好' starts at display col 2 -> 5+2=7
      assert cursor_col == 7, "Expected cursor at display col 7, got #{cursor_col}"
    end

    test "visual selection of CJK characters highlights correct grapheme cells" do
      ctx = start_editor("你好世界")

      # v selects '你', l extends to '好', l extends to '世'
      send_key_sync(ctx, ?v)
      send_key_sync(ctx, ?l)
      send_key_sync(ctx, ?l)

      screen = HeadlessPort.get_screen(ctx.port)
      row = Enum.at(screen.grid, @content_row)

      # HeadlessPort places one grapheme per cell at the draw command's col.
      # The draw command starts at display col 5 (gutter width: 2 sign + 2 digits + 1 space).
      # '你','好','世' land at cells 5, 6, 7 with :reverse.
      selected_cells = Enum.slice(row, 5, 3)

      assert Enum.all?(selected_cells, fn cell -> :reverse in cell.attrs end),
             "Expected cells 5-7 (你好世) to have :reverse attribute"

      # '界' at cell 8 must NOT be selected
      refute :reverse in Enum.at(row, 8).attrs,
             "Expected '界' at cell 8 to not be selected"
    end

    test "emoji renders as 2 display columns" do
      ctx = start_editor("🎉 party")

      assert_row_contains(ctx, @content_row, "🎉 party")
    end

    test "precomposed accented characters render as 1 display column" do
      # é (U+00E9, precomposed) = 2 bytes, 1 display col
      ctx = start_editor("é hello")

      assert_row_contains(ctx, @content_row, "é hello")

      # Moving right from 'é' should step 1 display col (to the space)
      send_key_sync(ctx, ?l)

      screen = HeadlessPort.get_screen(ctx.port)
      {_crow, cursor_col} = screen.cursor
      # gutter=5, é is 1 col wide, so after `l` cursor is at display col 1 -> col 5+1=6
      assert cursor_col == 6, "Expected cursor at col 6 (é is 1 col wide), got #{cursor_col}"
    end

    test "ASCII behavior is unchanged" do
      ctx = start_editor("hello world")

      assert_row_contains(ctx, @content_row, "hello world")

      send_key_sync(ctx, ?v)
      send_key_sync(ctx, ?l)
      send_key_sync(ctx, ?l)

      screen = HeadlessPort.get_screen(ctx.port)
      row = Enum.at(screen.grid, @content_row)
      # gutter=5; select "hel" = cols 5, 6, 7
      selected_cells = Enum.slice(row, 5, 3)

      assert Enum.all?(selected_cells, fn cell -> :reverse in cell.attrs end),
             "Expected ASCII selection cells to have :reverse attribute"
    end
  end

  describe "visual selection rendering" do
    # Gutter width for 1-line file: 5 (2 sign + 2 digits + 1 space)
    @sel_gutter_w 5

    test "selected text has reverse attribute" do
      ctx = start_editor("hello world")

      send_key_sync(ctx, ?v)
      send_key_sync(ctx, ?l)
      send_key_sync(ctx, ?l)

      screen = HeadlessPort.get_screen(ctx.port)
      row = Enum.at(screen.grid, @content_row)

      selected_cells = Enum.slice(row, @sel_gutter_w, 3)

      assert Enum.all?(selected_cells, fn cell -> :reverse in cell.attrs end),
             "Expected cells #{@sel_gutter_w}-#{@sel_gutter_w + 2} to have :reverse attribute"
    end
  end

  describe "scrolling" do
    test "content scrolls when cursor moves past viewport" do
      lines = Enum.map_join(0..30, "\n", &"line #{&1}")
      ctx = start_editor(lines, height: 10)

      # Set scroll margin to 0 on this buffer (not global) so we can
      # assert exact scroll positions without affecting other async tests.
      BufferServer.set_option(ctx.buffer, :scroll_margin, 0)

      for _ <- 1..10, do: send_key_sync(ctx, ?j)

      row_text = screen_row(ctx, @content_row)

      refute String.contains?(row_text, "line 0"),
             "Expected line 0 to have scrolled off, got: #{inspect(row_text)}"

      # In a 10-row terminal with tab bar, there are 7 content rows (rows 1-7).
      # After scrolling 10 lines, line 10 should be at the last content row.
      assert_row_contains(ctx, @content_row + 6, "line 10")
    end
  end

  describe "no file open" do
    test "shows empty buffer when no file is loaded" do
      id = :erlang.unique_integer([:positive])
      {:ok, port} = HeadlessPort.start_link(width: 80, height: 24)

      {:ok, editor} =
        Minga.Editor.start_link(
          name: :"headless_nofile_#{id}",
          port_manager: port,
          buffer: nil,
          width: 80,
          height: 24
        )

      send(editor, {:minga_input, {:ready, 80, 24}})
      :ok = HeadlessPort.await_frame(port)

      # Should show a normal editor with an empty buffer, not a dashboard
      screen = for row <- 0..23, do: HeadlessPort.get_row_text(port, row)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "[new 1]")
    end
  end
end
