defmodule Minga.Integration.WhichKeyTest do
  @moduledoc """
  Integration tests for the which-key popup: appearance after timeout,
  correct keybinding labels, nested prefix navigation, and clean dismissal.

  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Test.HeadlessPort

  # ── Popup appearance ───────────────────────────────────────────────────────

  describe "which-key popup after leader prefix" do
    test "popup appears after SPC + timeout with group labels" do
      ctx = start_editor("hello world")

      # Press SPC to enter leader mode
      send_keys(ctx, "<Space>")

      # The which-key popup is timer-based (300ms default).
      # Trigger it by sending the timeout message directly.
      trigger_whichkey_timeout(ctx)

      # Should show top-level groups (labels are prefixed with +)
      assert screen_contains?(ctx, "+file")
      assert screen_contains?(ctx, "+buffer")
      assert screen_contains?(ctx, "+ai")
      assert_screen_snapshot(ctx, "whichkey_top_level")
    end
  end

  # ── Nested prefix ─────────────────────────────────────────────────────────

  describe "which-key nested prefix" do
    test "SPC w shows window-specific bindings" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>w")
      trigger_whichkey_timeout(ctx)

      # Window group should show split/navigation bindings
      assert screen_contains?(ctx, "split") or screen_contains?(ctx, "Vertical") or
               screen_contains?(ctx, "Window")

      assert_screen_snapshot(ctx, "whichkey_window_prefix")
    end

    test "SPC b shows buffer-specific bindings" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>b")
      trigger_whichkey_timeout(ctx)

      assert screen_contains?(ctx, "buffer") or screen_contains?(ctx, "Switch") or
               screen_contains?(ctx, "Kill")

      assert_screen_snapshot(ctx, "whichkey_buffer_prefix")
    end
  end

  # ── Dismissal ──────────────────────────────────────────────────────────────

  describe "which-key dismissal" do
    test "completing a binding dismisses the popup" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>")
      trigger_whichkey_timeout(ctx)
      assert screen_contains?(ctx, "+file")

      # Complete the binding: SPC f f (find file) opens picker, closes which-key
      send_keys(ctx, "ff")

      # Which-key labels should be gone, picker should be visible instead
      refute screen_contains?(ctx, "+buffer")
      assert screen_contains?(ctx, "Find file")
    end

    test "escape dismisses the popup and returns to normal" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>")
      trigger_whichkey_timeout(ctx)

      send_keys(ctx, "<Esc>")

      assert editor_mode(ctx) == :normal
      assert_screen_snapshot(ctx, "whichkey_dismissed_by_escape")
    end
  end

  # ── Fast typing (no popup) ────────────────────────────────────────────────

  describe "fast typing skips which-key" do
    test "typing full sequence fast does not show popup" do
      ctx = start_editor("hello world")

      # Send the full SPC b b sequence without triggering timeout
      send_keys(ctx, "<Space>bb")

      # The picker should be open, but no which-key popup artifacts
      assert screen_contains?(ctx, "Switch buffer")
      # No group labels like "+file" should be visible
      refute screen_contains?(ctx, "+file")
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Triggers the which-key timeout by sending the timeout message
  # directly to the editor process, then waiting for the render frame.
  defp trigger_whichkey_timeout(%{editor: editor, port: port}) do
    state = :sys.get_state(editor)

    case state.whichkey.timer do
      ref when is_reference(ref) ->
        # Cancel the real timer and send the message immediately
        Process.cancel_timer(ref)
        ref_for_frame = HeadlessPort.prepare_await(port)
        send(editor, {:whichkey_timeout, ref})
        {:ok, snapshot} = HeadlessPort.collect_frame(ref_for_frame)
        Process.put({:last_frame_snapshot, port}, snapshot)

      _ ->
        # No timer active; popup may already be showing or leader cancelled
        :ok
    end
  end
end
