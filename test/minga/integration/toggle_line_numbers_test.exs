defmodule Minga.Integration.ToggleLineNumbersTest do
  @moduledoc """
  Integration tests for toggling line numbers via `SPC t l`.

  Verifies that the line number style actually changes on screen after
  toggling, not just in buffer state. This catches render cache invalidation
  regressions where the option changes but stale gutter draws are reused.
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Server, as: BufferServer

  @multi_line_content "line one\nline two\nline three\nline four\nline five"

  describe "SPC t l cycles line numbers" do
    test "cycles through hybrid → absolute → relative → none → hybrid" do
      ctx = start_editor(@multi_line_content)

      assert BufferServer.get_option(ctx.buffer, :line_numbers) == :hybrid

      send_keys(ctx, "<SPC>tl")
      assert BufferServer.get_option(ctx.buffer, :line_numbers) == :absolute

      send_keys(ctx, "<SPC>tl")
      assert BufferServer.get_option(ctx.buffer, :line_numbers) == :relative

      send_keys(ctx, "<SPC>tl")
      assert BufferServer.get_option(ctx.buffer, :line_numbers) == :none

      send_keys(ctx, "<SPC>tl")
      assert BufferServer.get_option(ctx.buffer, :line_numbers) == :hybrid
    end

    test "gutter content updates on screen after toggling to none and back" do
      ctx = start_editor(@multi_line_content)

      # Default is hybrid: line numbers visible in the gutter.
      row1 = screen_row(ctx, 1)
      row2 = screen_row(ctx, 2)
      assert row1 =~ ~r/1.*line one/, "hybrid: line 1 shows '1'"
      assert row2 =~ ~r/\d.*line two/, "hybrid: line 2 shows a number"

      # Cycle to none (hybrid → absolute → relative → none = 3 presses).
      send_keys(ctx, "<SPC>tl")
      send_keys(ctx, "<SPC>tl")
      send_keys(ctx, "<SPC>tl")
      assert BufferServer.get_option(ctx.buffer, :line_numbers) == :none

      row1 = screen_row(ctx, 1)
      assert row1 =~ ~r/^line one/, "none: no gutter, text starts immediately"
      refute row1 =~ ~r/^\s+\d/, "none: no line number padding"

      # One more press back to hybrid.
      send_keys(ctx, "<SPC>tl")
      assert BufferServer.get_option(ctx.buffer, :line_numbers) == :hybrid

      row1 = screen_row(ctx, 1)
      row2 = screen_row(ctx, 2)
      assert row1 =~ ~r/1.*line one/, "hybrid: line 1 shows '1' again"
      assert row2 =~ ~r/\d.*line two/, "hybrid: line 2 shows a number again"
    end
  end
end
