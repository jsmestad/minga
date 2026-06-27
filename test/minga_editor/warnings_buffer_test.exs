defmodule MingaEditor.WarningsBufferTest do
  use Minga.Test.EditorCase, async: true

  alias MingaEditor.BottomPanel
  alias MingaEditor.Frontend.Capabilities

  describe "warnings in native GUI" do
    test "SPC b W opens the warnings bottom panel" do
      ctx = start_editor("hello")
      set_gui_capabilities(ctx)

      send_keys_sync(ctx, "<SPC>bW")

      assert %{visible: true, active_tab: :messages, filter: :warnings} = bottom_panel(ctx)
    end

    test "warning-level events do not auto-open the panel" do
      ctx = start_editor("hello")
      set_gui_capabilities(ctx)

      broadcast_warning(ctx, "first warning")
      state = editor_state(ctx)
      refute state.shell_state.warning_popup_timer
      refute bottom_panel(ctx).visible
    end

    test "error-level events auto-open the panel unless dismissed" do
      ctx = start_editor("hello")
      set_gui_capabilities(ctx)

      broadcast_error(ctx, "something failed")
      flush_warning_popup(ctx)
      assert %{visible: true} = bottom_panel(ctx)

      dismiss_bottom_panel(ctx)
      broadcast_error(ctx, "another failure")
      flush_warning_popup(ctx)
      refute bottom_panel(ctx).visible
    end
  end

  describe "warnings in TUI" do
    test "warnings are stored and SPC b W opens the warning-filtered messages tray" do
      ctx = start_editor("hello")

      broadcast_warning(ctx, "something broke")
      editor_state(ctx)

      warning_entries = Enum.filter(message_store_entries(ctx), &(&1.level == :warning))

      assert Enum.any?(warning_entries, fn entry ->
               String.contains?(entry.text, "something broke")
             end)

      send_keys_sync(ctx, "<SPC>bW")

      assert %{visible: true, active_tab: :messages, filter: :warnings} = bottom_panel(ctx)
    end
  end

  defp broadcast_warning(ctx, text) do
    Minga.Events.broadcast(
      :log_message,
      %Minga.Events.LogMessageEvent{text: text, level: :warning},
      ctx.events_registry
    )
  end

  defp broadcast_error(ctx, text) do
    Minga.Events.broadcast(
      :log_message,
      %Minga.Events.LogMessageEvent{text: text, level: :error},
      ctx.events_registry
    )
  end

  defp set_gui_capabilities(ctx) do
    :sys.replace_state(ctx.editor, fn %{capabilities: %Capabilities{} = caps} = state ->
      %{state | capabilities: %Capabilities{caps | frontend_type: :native_gui}}
    end)
  end

  defp flush_warning_popup(ctx) do
    editor_state(ctx)
    send(ctx.editor, :warning_popup_timeout)
    editor_state(ctx)
  end

  defp bottom_panel(ctx), do: editor_state(ctx).shell_state.bottom_panel

  defp dismiss_bottom_panel(ctx) do
    :sys.replace_state(ctx.editor, fn state ->
      MingaEditor.State.set_bottom_panel(
        state,
        BottomPanel.dismiss(state.shell_state.bottom_panel)
      )
    end)
  end
end
