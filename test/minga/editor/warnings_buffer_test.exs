defmodule Minga.Editor.WarningsBufferTest do
  use Minga.Test.EditorCase, async: true

  describe "*Warnings* buffer" do
    test "SPC b W opens the warnings popup" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bW")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Warnings*")
    end

    test "SPC b W toggles the warnings popup closed" do
      ctx = start_editor("hello")

      # Open
      send_keys(ctx, "<SPC>bW")
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Warnings*")

      # Toggle closed
      send_keys(ctx, "<SPC>bW")
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      refute String.contains?(all_text, "*Warnings*")
    end

    test "q dismisses the warnings popup" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bW")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Warnings*")

      # Press q to dismiss
      send_keys(ctx, "q")
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      refute String.contains?(all_text, "*Warnings*")
    end

    test "warnings buffer is read-only" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bW")
      send_keys(ctx, "itest")

      # Should still be in normal mode (insert blocked on read-only buffer)
      assert editor_mode(ctx) == :normal
    end

    test ":warnings ex-command opens the warnings popup" do
      ctx = start_editor("hello")
      send_keys(ctx, ":warnings<CR>")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Warnings*")
    end
  end
end
