defmodule Minga.Editor.WarningsBufferTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.BottomPanel

  describe "warnings via bottom panel" do
    test "SPC b W opens bottom panel with warnings filter" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bW")

      state = :sys.get_state(ctx.editor)
      assert state.bottom_panel.visible == true
      assert state.bottom_panel.active_tab == :messages
      assert state.bottom_panel.filter == :warnings
      assert state.bottom_panel.dismissed == false
    end

    test "SPC b W resets dismissed state" do
      ctx = start_editor("hello")

      # Dismiss the panel first
      state = :sys.get_state(ctx.editor)
      dismissed_panel = BottomPanel.dismiss(state.bottom_panel)
      :sys.replace_state(ctx.editor, fn s -> %{s | bottom_panel: dismissed_panel} end)

      # Verify it's dismissed
      state = :sys.get_state(ctx.editor)
      assert state.bottom_panel.dismissed == true

      # SPC b W should reset dismissed and open
      send_keys(ctx, "<SPC>bW")
      state = :sys.get_state(ctx.editor)
      assert state.bottom_panel.visible == true
      assert state.bottom_panel.dismissed == false
    end

    test ":warnings ex-command opens bottom panel with warnings filter" do
      ctx = start_editor("hello")
      send_keys(ctx, ":warnings<CR>")

      state = :sys.get_state(ctx.editor)
      assert state.bottom_panel.visible == true
      assert state.bottom_panel.filter == :warnings
    end

    test "warnings logged after dismissal do not auto-open panel" do
      ctx = start_editor("hello")

      # Dismiss the bottom panel
      state = :sys.get_state(ctx.editor)
      dismissed_panel = BottomPanel.dismiss(state.bottom_panel)
      :sys.replace_state(ctx.editor, fn s -> %{s | bottom_panel: dismissed_panel} end)

      # Log a warning
      Minga.Editor.log_to_warnings("test warning after dismiss", ctx.editor)

      # Wait for debounce timer (200ms) plus margin
      Process.sleep(300)
      :sys.get_state(ctx.editor)

      state = :sys.get_state(ctx.editor)
      assert state.bottom_panel.visible == false
      assert state.bottom_panel.dismissed == true
    end

    test "warning auto-opens bottom panel when not dismissed" do
      ctx = start_editor("hello")

      # Ensure panel is not dismissed and not visible
      state = :sys.get_state(ctx.editor)
      assert state.bottom_panel.visible == false
      assert state.bottom_panel.dismissed == false

      # Log a warning
      Minga.Editor.log_to_warnings("test warning", ctx.editor)

      # Wait for debounce timer (200ms) plus margin
      Process.sleep(300)
      :sys.get_state(ctx.editor)

      state = :sys.get_state(ctx.editor)
      assert state.bottom_panel.visible == true
      assert state.bottom_panel.filter == :warnings
    end

    test "warning does not change filter when panel already open on Messages tab" do
      ctx = start_editor("hello")

      # Open the panel manually (no filter preset)
      send_keys(ctx, "<SPC>tp")
      state = :sys.get_state(ctx.editor)
      assert state.bottom_panel.visible == true
      assert state.bottom_panel.filter == nil

      # Log a warning
      Minga.Editor.log_to_warnings("test warning", ctx.editor)

      # Wait for debounce
      Process.sleep(300)
      :sys.get_state(ctx.editor)

      # Filter should not have changed
      state = :sys.get_state(ctx.editor)
      assert state.bottom_panel.visible == true
      assert state.bottom_panel.filter == nil
    end

    test "warnings appear in *Messages* gap buffer for TUI" do
      ctx = start_editor("hello")

      Minga.Editor.log_to_warnings("something broke", ctx.editor)
      :sys.get_state(ctx.editor)

      state = :sys.get_state(ctx.editor)
      content = BufferServer.content(state.buffers.messages)
      assert String.contains?(content, "[WARN] something broke")
    end

    test "warnings appear in MessageStore with warning level" do
      ctx = start_editor("hello")

      Minga.Editor.log_to_warnings("something broke", ctx.editor)
      :sys.get_state(ctx.editor)

      state = :sys.get_state(ctx.editor)
      entries = state.message_store.entries

      warning_entries = Enum.filter(entries, fn e -> e.level == :warning end)
      assert warning_entries != []
      assert Enum.any?(warning_entries, fn e -> String.contains?(e.text, "something broke") end)
    end
  end
end
