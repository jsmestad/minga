defmodule MingaEditor.Renderer.ConcealRenderTest do
  @moduledoc """
  Visible rendering smoke tests for conceal ranges.

  Decoration storage and raw buffer contents are covered at cheaper buffer/decoration layers. This file keeps only the user-visible rendering promises: non-cursor lines conceal text, replacement characters render, cursor lines reveal raw text, and removing conceals restores the display.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations

  @content_row 1

  describe "conceal rendering" do
    test "non-cursor lines conceal text while the cursor line reveals it" do
      ctx = start_editor("**bold**\n**italic**")

      BufferProcess.batch_decorations(ctx.buffer, fn decs ->
        decs
        |> add_conceal({0, 0}, {0, 2})
        |> add_conceal({0, 6}, {0, 8})
        |> add_conceal({1, 0}, {1, 2})
        |> add_conceal({1, 8}, {1, 10})
      end)

      send_key_sync(ctx, 0)

      cursor_line = screen_row(ctx, @content_row)
      non_cursor_line = screen_row(ctx, @content_row + 1)

      assert cursor_line =~ "**bold**"
      refute non_cursor_line =~ "**"
      assert non_cursor_line =~ "italic"
    end

    test "replacement characters render on non-cursor lines" do
      ctx = start_editor("**bold**\nsecond line")

      BufferProcess.batch_decorations(ctx.buffer, fn decs ->
        decs
        |> add_conceal({0, 0}, {0, 2}, replacement: "·")
        |> add_conceal({0, 6}, {0, 8}, replacement: "·")
      end)

      send_key_sync(ctx, ?j)
      row_text = screen_row(ctx, @content_row)

      assert row_text =~ "·"
      assert row_text =~ "bold"
    end

    test "removing conceals restores the raw display" do
      ctx = start_editor("**bold**\nsecond line")

      BufferProcess.batch_decorations(ctx.buffer, fn decs ->
        add_conceal(decs, {0, 0}, {0, 2})
      end)

      send_key_sync(ctx, ?j)

      BufferProcess.batch_decorations(ctx.buffer, fn decs ->
        Decorations.remove_conceal_group(decs, :test)
      end)

      send_key_sync(ctx, ?k)

      assert screen_row(ctx, @content_row) =~ "**bold"
    end
  end

  defp add_conceal(decs, start_pos, end_pos, opts \\ []) do
    {_id, decs} =
      Decorations.add_conceal(decs, start_pos, end_pos, Keyword.put(opts, :group, :test))

    decs
  end
end
