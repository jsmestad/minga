defmodule Minga.RenderTest do
  @moduledoc """
  Tests that verify *rendered output* via the headless port harness.

  These tests exercise the full pipeline: buffer → editor FSM → render
  commands → virtual screen grid. They assert on what the user would
  actually see, not just buffer state.
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

      # Row 0 has content, rows 1..7 should have tildes (8 content rows with 2 footer)
      assert_row_contains(ctx, 0, "just one line")
      assert_row_contains(ctx, 1, "~")
    end

    test "renders unicode content correctly" do
      ctx = start_editor("héllo wörld 🎉\nñoño")

      assert_row_contains(ctx, 0, "héllo wörld")
      assert_row_contains(ctx, 1, "ñoño")
    end
  end

  describe "modeline" do
    test "shows NORMAL mode on startup" do
      ctx = start_editor("hello")
      assert_mode(ctx, :normal)
    end

    test "shows filename in modeline" do
      ctx = start_editor("content", file_path: "/tmp/test_file.txt")
      assert_modeline_contains(ctx, "test_file.txt")
    end

    test "shows cursor position" do
      ctx = start_editor("hello\nworld")
      # Initial position: 1:1 (1-indexed display)
      assert_modeline_contains(ctx, "1:1")
    end

    test "updates cursor position after movement" do
      ctx = start_editor("hello\nworld")

      send_key(ctx, ?j)
      send_key(ctx, ?l)
      send_key(ctx, ?l)

      assert_modeline_contains(ctx, "2:3")
    end

    test "shows INSERT mode after pressing i" do
      ctx = start_editor("hello")
      send_key(ctx, ?i)
      assert_mode(ctx, :insert)
    end

    test "shows VISUAL mode after pressing v" do
      ctx = start_editor("hello")
      send_key(ctx, ?v)
      assert_mode(ctx, :visual)
    end

    test "returns to NORMAL mode after Esc from insert" do
      ctx = start_editor("hello")
      send_key(ctx, ?i)
      assert_mode(ctx, :insert)
      send_key(ctx, 27)
      assert_mode(ctx, :normal)
    end

    test "shows dirty indicator after editing" do
      ctx = start_editor("hello")

      send_key(ctx, ?i)
      send_key(ctx, ?x)
      send_key(ctx, 27)

      assert_modeline_contains(ctx, "●")
    end
  end

  describe "command mode / minibuffer" do
    test "shows colon and typed command in minibuffer" do
      ctx = start_editor("hello")

      send_key(ctx, ?:)
      send_key(ctx, ?w)
      send_key(ctx, ?q)

      assert_minibuffer_contains(ctx, ":wq")
    end

    test "shows COMMAND mode in modeline" do
      ctx = start_editor("hello")
      send_key(ctx, ?:)
      assert_mode(ctx, :command)
    end

    test "minibuffer clears after Esc" do
      ctx = start_editor("hello")

      send_key(ctx, ?:)
      send_key(ctx, ?w)
      send_key(ctx, 27)

      # Back to normal, minibuffer should be empty
      assert_mode(ctx, :normal)
      mb = minibuffer(ctx)
      refute String.contains?(mb, ":w")
    end

    test "cursor moves to minibuffer in command mode" do
      ctx = start_editor("hello")

      send_key(ctx, ?:)
      send_key(ctx, ?q)

      {cursor_row, cursor_col} = screen_cursor(ctx)
      assert cursor_row == ctx.height - 1
      # After `:q`, cursor should be at column 2 (after `:` and `q`)
      assert cursor_col == 2
    end
  end

  describe "cursor shape" do
    test "block cursor in normal mode" do
      ctx = start_editor("hello")
      assert cursor_shape(ctx) == :block
    end

    test "beam cursor in insert mode" do
      ctx = start_editor("hello")
      send_key(ctx, ?i)
      assert cursor_shape(ctx) == :beam
    end

    test "block cursor in visual mode" do
      ctx = start_editor("hello")
      send_key(ctx, ?v)
      assert cursor_shape(ctx) == :block
    end

    test "restores block cursor when leaving insert mode" do
      ctx = start_editor("hello")
      send_key(ctx, ?i)
      assert cursor_shape(ctx) == :beam
      send_key(ctx, 27)
      assert cursor_shape(ctx) == :block
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

  describe "screen cursor position" do
    # Gutter width for 2-line file: 3 (2 digits + 1 separator)
    @gutter_w 3

    test "cursor starts at gutter offset" do
      ctx = start_editor("hello\nworld")
      assert screen_cursor(ctx) == {0, @gutter_w}
    end

    test "cursor follows hjkl movement with gutter offset" do
      ctx = start_editor("hello\nworld")

      send_key(ctx, ?l)
      send_key(ctx, ?l)
      assert screen_cursor(ctx) == {0, @gutter_w + 2}

      send_key(ctx, ?j)
      assert screen_cursor(ctx) == {1, @gutter_w + 2}
    end
  end

  describe "visual selection rendering" do
    # Gutter width for 1-line file: 3
    @sel_gutter_w 3

    test "selected text has reverse attribute" do
      ctx = start_editor("hello world")

      # Enter visual mode and select a few characters
      send_key(ctx, ?v)
      send_key(ctx, ?l)
      send_key(ctx, ?l)

      # Check that the screen has cells with reverse styling
      screen = HeadlessPort.get_screen(ctx.port)
      row = Enum.at(screen.grid, 0)

      # Content starts after gutter; cells gutter_w..gutter_w+2 should be selected
      selected_cells = Enum.slice(row, @sel_gutter_w, 3)

      assert Enum.all?(selected_cells, fn cell -> :reverse in cell.attrs end),
             "Expected cells #{@sel_gutter_w}-#{@sel_gutter_w + 2} to have :reverse attribute"
    end
  end

  describe "scrolling" do
    test "content scrolls when cursor moves past viewport" do
      lines = Enum.map_join(0..30, "\n", &"line #{&1}")
      # Small viewport: 10 rows = 8 content rows + 2 footer
      ctx = start_editor(lines, height: 10)

      # Move down past the viewport
      for _ <- 1..10, do: send_key(ctx, ?j)

      # Row 0 should no longer show "line 0"
      row0 = screen_row(ctx, 0)

      refute String.contains?(row0, "line 0"),
             "Expected line 0 to have scrolled off, got: #{inspect(row0)}"

      # The cursor's line should be visible somewhere
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
