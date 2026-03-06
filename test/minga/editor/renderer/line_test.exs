defmodule Minga.Editor.Renderer.LineTest do
  @moduledoc """
  Tests for line content rendering: file content, unicode, insert mode,
  visual selection, scrolling, and tilde rows.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Test.HeadlessPort

  describe "file content rendering" do
    test "opens a file and renders its content on screen" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      assert_row_contains(ctx, 0, "hello world")
      assert_row_contains(ctx, 1, "second line")
      assert_row_contains(ctx, 2, "third line")
    end

    test "empty lines below content show tildes" do
      ctx = start_editor("just one line", height: 10)

      assert_row_contains(ctx, 0, "just one line")
      assert_row_contains(ctx, 1, "~")
    end

    test "renders unicode content correctly" do
      ctx = start_editor("héllo wörld 🎉\nñoño")

      assert_row_contains(ctx, 0, "héllo wörld")
      assert_row_contains(ctx, 1, "ñoño")
    end
  end

  describe "insert mode rendering" do
    test "typed characters appear on screen" do
      ctx = start_editor("hello")

      send_key(ctx, ?i)
      send_key(ctx, ?X)
      send_key(ctx, ?Y)

      assert_row_contains(ctx, 0, "XYhello")
    end

    test "newline in insert mode creates a new line on screen" do
      ctx = start_editor("hello")

      send_key(ctx, ?i)
      send_key(ctx, 13)

      assert_row_contains(ctx, 1, "hello")
    end
  end

  describe "wide character (CJK / emoji) rendering" do
    test "CJK characters render without overlap or gaps" do
      ctx = start_editor("你好世界")

      assert_row_contains(ctx, 0, "你好世界")
    end

    test "cursor on CJK character lands at correct display column" do
      ctx = start_editor("你好")

      # Move right once — cursor steps to second CJK char (display col 2)
      send_key(ctx, ?l)

      screen = HeadlessPort.get_screen(ctx.port)
      {cursor_row, cursor_col} = screen.cursor

      assert cursor_row == 0
      # Gutter width for 1-line file is 3; '好' starts at display col 2 → 3+2=5
      assert cursor_col == 5, "Expected cursor at display col 5, got #{cursor_col}"
    end

    test "visual selection of CJK characters highlights correct grapheme cells" do
      ctx = start_editor("你好世界")

      # v selects '你', l extends to '好', l extends to '世'
      send_key(ctx, ?v)
      send_key(ctx, ?l)
      send_key(ctx, ?l)

      screen = HeadlessPort.get_screen(ctx.port)
      row = Enum.at(screen.grid, 0)

      # HeadlessPort places one grapheme per cell at the draw command's col.
      # The draw command starts at display col 3 (gutter width).
      # '你','好','世' land at cells 3, 4, 5 with :reverse.
      selected_cells = Enum.slice(row, 3, 3)

      assert Enum.all?(selected_cells, fn cell -> :reverse in cell.attrs end),
             "Expected cells 3-5 (你好世) to have :reverse attribute"

      # '界' at cell 6 must NOT be selected
      refute :reverse in Enum.at(row, 6).attrs,
             "Expected '界' at cell 6 to not be selected"
    end

    test "emoji renders as 2 display columns" do
      ctx = start_editor("🎉 party")

      assert_row_contains(ctx, 0, "🎉 party")
    end

    test "precomposed accented characters render as 1 display column" do
      # é (U+00E9, precomposed) = 2 bytes, 1 display col
      ctx = start_editor("é hello")

      assert_row_contains(ctx, 0, "é hello")

      # Moving right from 'é' should step 1 display col (to the space)
      send_key(ctx, ?l)

      screen = HeadlessPort.get_screen(ctx.port)
      {_crow, cursor_col} = screen.cursor
      # gutter=3, é is 1 col wide, so after `l` cursor is at display col 1 → col 3+1=4
      assert cursor_col == 4, "Expected cursor at col 4 (é is 1 col wide), got #{cursor_col}"
    end

    test "ASCII behavior is unchanged" do
      ctx = start_editor("hello world")

      assert_row_contains(ctx, 0, "hello world")

      send_key(ctx, ?v)
      send_key(ctx, ?l)
      send_key(ctx, ?l)

      screen = HeadlessPort.get_screen(ctx.port)
      row = Enum.at(screen.grid, 0)
      # gutter=3; select "hel" = cols 3, 4, 5
      selected_cells = Enum.slice(row, 3, 3)

      assert Enum.all?(selected_cells, fn cell -> :reverse in cell.attrs end),
             "Expected ASCII selection cells to have :reverse attribute"
    end
  end

  describe "visual selection rendering" do
    # Gutter width for 1-line file: 3
    @sel_gutter_w 3

    test "selected text has reverse attribute" do
      ctx = start_editor("hello world")

      send_key(ctx, ?v)
      send_key(ctx, ?l)
      send_key(ctx, ?l)

      screen = HeadlessPort.get_screen(ctx.port)
      row = Enum.at(screen.grid, 0)

      selected_cells = Enum.slice(row, @sel_gutter_w, 3)

      assert Enum.all?(selected_cells, fn cell -> :reverse in cell.attrs end),
             "Expected cells #{@sel_gutter_w}-#{@sel_gutter_w + 2} to have :reverse attribute"
    end
  end

  describe "scrolling" do
    test "content scrolls when cursor moves past viewport" do
      # Disable scroll margin so we can assert exact scroll positions
      alias Minga.Config.Options
      Options.set(:scroll_margin, 0)

      lines = Enum.map_join(0..30, "\n", &"line #{&1}")
      ctx = start_editor(lines, height: 10)

      for _ <- 1..10, do: send_key(ctx, ?j)

      row0 = screen_row(ctx, 0)

      refute String.contains?(row0, "line 0"),
             "Expected line 0 to have scrolled off, got: #{inspect(row0)}"

      assert_row_contains(ctx, 7, "line 10")
    end
  end

  describe "no file open" do
    test "shows scratch buffer when no file is loaded" do
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

      row0 = HeadlessPort.get_row_text(port, 0)
      # With special buffers, the editor now starts with *scratch* instead of splash
      assert String.contains?(row0, "# This buffer") or String.contains?(row0, "Minga")
    end
  end
end
