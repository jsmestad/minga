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

    test "dismissing with q sets warnings_popup_dismissed flag" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bW")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Warnings*")

      # Dismiss with q
      send_keys(ctx, "q")
      state = :sys.get_state(ctx.editor)
      assert state.warnings_popup_dismissed == true
    end

    test "SPC b W resets warnings_popup_dismissed flag" do
      ctx = start_editor("hello")

      # Open and dismiss to set the flag
      send_keys(ctx, "<SPC>bW")
      send_keys(ctx, "q")
      state = :sys.get_state(ctx.editor)
      assert state.warnings_popup_dismissed == true

      # Explicitly re-open with SPC b W
      send_keys(ctx, "<SPC>bW")
      state = :sys.get_state(ctx.editor)
      assert state.warnings_popup_dismissed == false
    end

    test "warnings logged after dismissal do not re-open the popup" do
      ctx = start_editor("hello")

      # Open and dismiss
      send_keys(ctx, "<SPC>bW")
      send_keys(ctx, "q")

      # Log a warning (goes through the Editor cast path)
      Minga.Editor.log_to_warnings("test warning after dismiss", ctx.editor)

      # Wait for the debounce timer (200ms) plus margin
      Process.sleep(300)
      :sys.get_state(ctx.editor)

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
