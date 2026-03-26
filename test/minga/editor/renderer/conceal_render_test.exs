defmodule Minga.Editor.Renderer.ConcealRenderTest do
  @moduledoc """
  Tests that conceal ranges actually affect rendering output.

  Uses the headless editor to verify that concealed characters disappear
  from the display and replacement characters appear when specified.
  Conceals are revealed on the cursor line (Neovim concealcursor behavior).
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Core.Decorations

  # Content starts at row 1 because the tab bar occupies row 0.
  @content_row 1

  describe "conceal rendering" do
    test "concealed characters are hidden on non-cursor line" do
      # Conceals on line 0, cursor on line 1
      ctx = start_editor("**bold**\nsecond line")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id1, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2}, group: :test)
        {_id2, decs} = Decorations.add_conceal(decs, {0, 6}, {0, 8}, group: :test)
        decs
      end)

      # Move cursor to line 1 so line 0 conceals are active
      send_key_sync(ctx, ?j)

      row_text = screen_row(ctx, @content_row)

      refute String.contains?(row_text, "**"),
             "Expected ** to be concealed on non-cursor line, got: #{inspect(row_text)}"

      assert String.contains?(row_text, "bold"),
             "Expected 'bold' to be visible, got: #{inspect(row_text)}"
    end

    test "conceal with replacement character shows replacement on non-cursor line" do
      ctx = start_editor("**bold**\nsecond line")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id1, decs} =
          Decorations.add_conceal(decs, {0, 0}, {0, 2}, replacement: "·", group: :test)

        {_id2, decs} =
          Decorations.add_conceal(decs, {0, 6}, {0, 8}, replacement: "·", group: :test)

        decs
      end)

      # Move cursor to line 1
      send_key_sync(ctx, ?j)

      row_text = screen_row(ctx, @content_row)

      assert String.contains?(row_text, "·"),
             "Expected replacement char on non-cursor line, got: #{inspect(row_text)}"

      assert String.contains?(row_text, "bold"),
             "Expected 'bold' to be visible, got: #{inspect(row_text)}"
    end

    test "buffer content is not modified by concealment" do
      ctx = start_editor("**bold**")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2}, group: :test)
        decs
      end)

      content = BufferServer.content(ctx.buffer)
      assert content == "**bold**"
    end

    test "removing conceals restores display" do
      ctx = start_editor("**bold**\nsecond line")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2}, group: :test)
        decs
      end)

      # Move cursor off line 0, then remove conceals
      send_key_sync(ctx, ?j)

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        Decorations.remove_conceal_group(decs, :test)
      end)

      # Move back to line 0 to re-render
      send_key_sync(ctx, ?k)

      row_text = screen_row(ctx, @content_row)

      assert String.contains?(row_text, "**bold"),
             "Expected ** to be visible after removal, got: #{inspect(row_text)}"
    end

    test "multiple conceals on one line" do
      ctx = start_editor("# Heading\nsecond line")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2}, group: :test)
        decs
      end)

      # Move cursor to line 1 so line 0 conceals are active
      send_key_sync(ctx, ?j)

      row_text = screen_row(ctx, @content_row)

      assert String.contains?(row_text, "Heading"),
             "Expected 'Heading' to be visible, got: #{inspect(row_text)}"
    end

    test "cursor line reveals concealed text" do
      ctx = start_editor("**bold**\nnormal line")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id1, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2}, group: :test)
        {_id2, decs} = Decorations.add_conceal(decs, {0, 6}, {0, 8}, group: :test)
        decs
      end)

      send_key_sync(ctx, 0)

      # Cursor is on line 0, so conceals should be revealed
      row_text = screen_row(ctx, @content_row)

      assert String.contains?(row_text, "**"),
             "Expected ** to be revealed on cursor line, got: #{inspect(row_text)}"
    end

    test "non-cursor line hides concealed text while cursor line reveals" do
      ctx = start_editor("**bold**\n**italic**")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id1, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2}, group: :test)
        {_id2, decs} = Decorations.add_conceal(decs, {0, 6}, {0, 8}, group: :test)
        {_id3, decs} = Decorations.add_conceal(decs, {1, 0}, {1, 2}, group: :test)
        {_id4, decs} = Decorations.add_conceal(decs, {1, 8}, {1, 10}, group: :test)
        decs
      end)

      send_key_sync(ctx, 0)

      # Cursor is on line 0: line 0 reveals, line 1 conceals
      row_text_line1 = screen_row(ctx, @content_row + 1)

      refute String.contains?(row_text_line1, "**"),
             "Expected ** to be hidden on non-cursor line, got: #{inspect(row_text_line1)}"

      assert String.contains?(row_text_line1, "italic"),
             "Expected 'italic' to be visible, got: #{inspect(row_text_line1)}"
    end

    test "yank across concealed range produces raw text" do
      ctx = start_editor("**bold**", clipboard: :none)

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id1, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2}, group: :test)
        {_id2, decs} = Decorations.add_conceal(decs, {0, 6}, {0, 8}, group: :test)
        decs
      end)

      # Yank the line
      send_keys_sync(ctx, "Vy")

      content = BufferServer.content(ctx.buffer)
      assert content == "**bold**"
    end
  end
end
