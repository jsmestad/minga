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
    test "shows splash screen when no buffer is loaded" do
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
      assert String.contains?(row0, "Minga")
    end
  end
end
