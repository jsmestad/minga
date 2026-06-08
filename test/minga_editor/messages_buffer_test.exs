defmodule MingaEditor.MessagesBufferTest do
  @moduledoc """
  Thin EditorCase smoke tests for the `*Messages*` buffer UI.

  Singleton lifecycle and log-routing contracts live in `Minga.Log.MessagesBufferTest`. These tests keep only the editor-facing promises: the keybinding opens/toggles the popup, the buffer stays read-only through the editor, editor lifecycle does not own the singleton, and GUI MessageStore broadcasts still receive external log events.
  """

  use Minga.Test.EditorCase, async: true

  defp unique_tag(prefix) do
    "msgtest-#{prefix}-#{System.unique_integer([:positive])}"
  end

  describe "Messages tray" do
    test "SPC b m opens the bottom messages tray without replacing the active buffer" do
      ctx = start_editor("hello")
      active_before = active_window_buffer(ctx)

      send_keys_sync(ctx, "<SPC>bm")

      assert %{visible: true, active_tab: :messages, filter: nil} = bottom_panel(ctx)
      assert active_window_buffer(ctx) == active_before
    end

    test "messages tray does not block normal editor input" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bm")
      send_keys_sync(ctx, "i")

      assert editor_mode(ctx) == :insert
    end
  end

  describe "singleton ownership" do
    test "editor lifecycle does not replace or stop the singleton buffer" do
      pid_before = Minga.Log.messages_buffer()
      assert is_pid(pid_before)
      assert Process.alive?(pid_before)

      ctx = start_editor("x")
      Process.unlink(ctx.editor)
      :ok = GenServer.stop(ctx.editor, :normal)

      assert Minga.Log.messages_buffer() == pid_before
      assert Process.alive?(pid_before)
      assert Minga.Buffer.buffer_name(pid_before) == "*Messages*"
    end
  end

  describe "MessageStore dual-write" do
    test "external broadcasts append to the editor's MessageStore" do
      tag = unique_tag("store-broadcast")
      ctx = start_editor("hello")

      Minga.Events.broadcast(
        :log_message,
        %Minga.Events.LogMessageEvent{
          text: tag,
          level: :warning
        },
        ctx.events_registry
      )

      assert Enum.any?(message_store_entries(ctx), fn entry ->
               String.contains?(entry.text, tag) and entry.level == :warning
             end)
    end
  end

  defp bottom_panel(ctx), do: editor_state(ctx).shell_state.bottom_panel
end
