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

    test "warning popup opens unless the panel was dismissed" do
      ctx = start_editor("hello")
      set_gui_capabilities(ctx)

      MingaEditor.log_to_warnings("first warning", ctx.editor)
      flush_warning_popup(ctx)
      assert %{visible: true, filter: :warnings} = bottom_panel(ctx)

      dismiss_bottom_panel(ctx)
      MingaEditor.log_to_warnings("second warning", ctx.editor)
      flush_warning_popup(ctx)
      refute bottom_panel(ctx).visible
    end
  end

  describe "warnings in TUI" do
    test "SPC b W opens the Messages buffer fallback" do
      ctx = start_editor("hello")

      send_keys_sync(ctx, "<SPC>bW")

      assert Enum.join(screen_text(ctx), "\n") =~ "*Messages*"
    end

    test "warnings are stored with warning level" do
      ctx = start_editor("hello")

      MingaEditor.log_to_warnings("something broke", ctx.editor)
      editor_state(ctx)

      warning_entries = Enum.filter(message_store_entries(ctx), &(&1.level == :warning))

      assert Enum.any?(warning_entries, fn entry ->
               String.contains?(entry.text, "something broke")
             end)
    end
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
