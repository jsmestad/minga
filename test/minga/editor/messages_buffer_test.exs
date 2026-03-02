defmodule Minga.Editor.MessagesBufferTest do
  @moduledoc """
  Tests for the *Messages* buffer and SPC b m.
  """

  use Minga.Test.EditorCase, async: true

  describe "*Messages* buffer" do
    test "SPC b m switches to messages buffer" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bm")

      ml = modeline(ctx)
      assert String.contains?(ml, "*Messages*")
    end

    test "messages buffer contains editor startup log" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bm")

      row0 = screen_row(ctx, 0)
      assert String.contains?(row0, "Editor started")
    end

    test "messages buffer shows [RO] indicator" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bm")

      ml = modeline(ctx)
      assert String.contains?(ml, "[RO]")
    end

    test "entering insert mode on messages buffer is blocked" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bm")
      send_keys(ctx, "i")

      assert editor_mode(ctx) == :normal
      mb = minibuffer(ctx)
      assert String.contains?(mb, "read-only")
    end

    test "messages buffer is hidden from buffer picker" do
      ctx = start_editor("hello")

      send_keys(ctx, "<SPC>bb")
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")

      refute String.contains?(all_text, "*Messages*")
    end
  end
end
