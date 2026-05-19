defmodule MingaEditor.MessagesBufferTest do
  @moduledoc """
  Thin EditorCase smoke tests for the `*Messages*` buffer UI.

  Singleton lifecycle and log-routing contracts live in `Minga.Log.MessagesBufferTest`. These tests keep only the editor-facing promises: the keybinding opens/toggles the popup, the buffer stays read-only through the editor, editor lifecycle does not own the singleton, and GUI MessageStore broadcasts still receive external log events.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer

  defp unique_tag(prefix) do
    "msgtest-#{prefix}-#{System.unique_integer([:positive])}"
  end

  describe "*Messages* buffer popup" do
    test "SPC b m opens a read-only messages popup and toggles it closed" do
      ctx = start_editor("hello")

      send_keys_sync(ctx, "<SPC>bm")
      popup_text = screen_text(ctx) |> Enum.join("\n")
      assert popup_text =~ "*Messages*"
      assert popup_text =~ "[RO]"

      send_keys_sync(ctx, "<SPC>bm")
      closed_text = screen_text(ctx) |> Enum.join("\n")
      refute closed_text =~ "*Messages*"
    end

    test "insert mode is blocked in the read-only messages buffer" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bm")
      send_keys_sync(ctx, "i")

      assert editor_mode(ctx) == :normal
      assert screen_text(ctx) |> Enum.join("\n") |> String.contains?("read-only")
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
      assert Buffer.buffer_name(pid_before) == "*Messages*"
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
end
