defmodule MingaEditor.WarningsBufferTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor.BottomPanel
  alias MingaEditor.Frontend.Capabilities

  # Helper to switch the editor to GUI capabilities so bottom panel commands work.
  defp set_gui_capabilities(ctx) do
    :sys.replace_state(ctx.editor, fn %{capabilities: %Capabilities{} = caps} = s ->
      %{s | capabilities: %Capabilities{caps | frontend_type: :native_gui}}
    end)
  end

  # Flushes the async log_to_warnings cast and fires the 200ms debounce
  # timer immediately. The cast schedules :warning_popup_timeout via
  # Process.send_after; we trigger it directly instead of sleeping.
  defp flush_warning_popup(ctx) do
    # First :sys.get_state flushes the cast (which schedules the debounce timer)
    :sys.get_state(ctx.editor)
    # Fire the timeout immediately instead of waiting 200ms
    send(ctx.editor, :warning_popup_timeout)
    # Second :sys.get_state flushes the timeout handler
    :sys.get_state(ctx.editor)
  end

  describe "warnings (GUI: bottom panel)" do
    test "SPC b W opens bottom panel with warnings filter" do
      ctx = start_editor("hello")
      set_gui_capabilities(ctx)
      send_keys_sync(ctx, "<SPC>bW")

      state = :sys.get_state(ctx.editor)
      assert state.shell_state.bottom_panel.visible == true
      assert state.shell_state.bottom_panel.active_tab == :messages
      assert state.shell_state.bottom_panel.filter == :warnings
    end

    test "SPC b W resets dismissed state" do
      ctx = start_editor("hello")
      set_gui_capabilities(ctx)

      # Dismiss the panel first
      :sys.replace_state(ctx.editor, fn s ->
        MingaEditor.State.set_bottom_panel(s, BottomPanel.dismiss(s.shell_state.bottom_panel))
      end)

      send_keys_sync(ctx, "<SPC>bW")
      state = :sys.get_state(ctx.editor)
      assert state.shell_state.bottom_panel.visible == true
      assert state.shell_state.bottom_panel.dismissed == false
    end

    test ":warnings ex-command opens bottom panel with warnings filter" do
      ctx = start_editor("hello")
      set_gui_capabilities(ctx)
      send_keys_sync(ctx, ":warnings<CR>")

      state = :sys.get_state(ctx.editor)
      assert state.shell_state.bottom_panel.visible == true
      assert state.shell_state.bottom_panel.filter == :warnings
    end

    test "warning auto-opens bottom panel when not dismissed" do
      ctx = start_editor("hello")
      set_gui_capabilities(ctx)

      MingaEditor.log_to_warnings("test warning", ctx.editor)
      flush_warning_popup(ctx)

      state = :sys.get_state(ctx.editor)
      assert state.shell_state.bottom_panel.visible == true
      assert state.shell_state.bottom_panel.filter == :warnings
    end

    test "warnings logged after dismissal do not auto-open panel" do
      ctx = start_editor("hello")
      set_gui_capabilities(ctx)

      :sys.replace_state(ctx.editor, fn s ->
        MingaEditor.State.set_bottom_panel(s, BottomPanel.dismiss(s.shell_state.bottom_panel))
      end)

      MingaEditor.log_to_warnings("test warning after dismiss", ctx.editor)
      flush_warning_popup(ctx)

      state = :sys.get_state(ctx.editor)
      assert state.shell_state.bottom_panel.visible == false
    end

    test "warning does not change filter when panel already open on Messages tab" do
      ctx = start_editor("hello")
      set_gui_capabilities(ctx)

      # Open panel manually (no filter)
      send_keys_sync(ctx, "<SPC>tp")
      state = :sys.get_state(ctx.editor)
      assert state.shell_state.bottom_panel.visible == true
      assert state.shell_state.bottom_panel.filter == nil

      MingaEditor.log_to_warnings("test warning", ctx.editor)
      flush_warning_popup(ctx)

      state = :sys.get_state(ctx.editor)
      assert state.shell_state.bottom_panel.filter == nil
    end
  end

  describe "warnings (TUI: *Messages* buffer fallback)" do
    test "SPC b W opens *Messages* buffer on TUI" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bW")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Messages*")
    end

    test "SPC b m opens *Messages* buffer on TUI" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bm")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Messages*")
    end

    test "warnings appear in *Messages* gap buffer with [WARN] prefix" do
      ctx = start_editor("hello")

      MingaEditor.log_to_warnings("something broke", ctx.editor)
      :sys.get_state(ctx.editor)

      state = :sys.get_state(ctx.editor)
      content = BufferServer.content(state.workspace.buffers.messages)
      assert String.contains?(content, "[WARN] something broke")
    end

    test "warnings appear in MessageStore with warning level" do
      ctx = start_editor("hello")

      MingaEditor.log_to_warnings("something broke", ctx.editor)
      :sys.get_state(ctx.editor)

      state = :sys.get_state(ctx.editor)
      warning_entries = Enum.filter(state.message_store.entries, fn e -> e.level == :warning end)
      assert warning_entries != []
      assert Enum.any?(warning_entries, fn e -> String.contains?(e.text, "something broke") end)
    end
  end
end
