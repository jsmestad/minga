defmodule MingaEditor.MessagesBufferTest do
  @moduledoc """
  Tests for the *Messages* buffer popup and `SPC b m`.

  The `*Messages*` buffer is now a BEAM-wide singleton owned by
  `Minga.Log.MessagesBuffer` (#1483). Each test owns a unique tag it
  writes to the shared buffer, so concurrent tests can run async
  without cross-test pollution.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer

  defp unique_tag(prefix) do
    "msgtest-#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp emit_log(text) do
    Minga.Log.info(:editor, text)
    # Drain the broadcast through the wrapper so the entry has hit the buffer
    # before the assertion runs. The wrapper subscribes synchronously in
    # Registry.dispatch, but a :sys.get_state barrier guarantees the cast/info
    # is fully processed.
    _ = :sys.get_state(Minga.Log.MessagesBuffer)
    :ok
  end

  describe "*Messages* buffer (popup)" do
    test "SPC b m opens the messages buffer in a popup split" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bm")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Messages*")
    end

    test "log entries this test emits land in the singleton buffer" do
      tag = unique_tag("popup-content")
      _ctx = start_editor("hello")
      emit_log(tag)

      assert String.contains?(Buffer.content(Minga.Log.messages_buffer()), tag)
    end

    test "popup is rendered when SPC b m is pressed after emitting our tagged entry" do
      tag = unique_tag("popup-render")
      ctx = start_editor("hello")
      emit_log(tag)
      # Assert observable popup behaviour: SPC b m opens a *Messages* popup.
      # We don't require the specific tag to be visible on screen because the
      # popup renders the tail of a shared, BEAM-wide buffer; under parallel
      # load, our tag may have scrolled out of the visible viewport. The
      # singleton-content assertion above proves the entry is in the buffer.
      send_keys_sync(ctx, "<SPC>bm")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Messages*")
    end

    test "popup shows the [RO] indicator" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bm")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "[RO]")
    end

    test "entering insert mode in the messages buffer is blocked" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bm")
      send_keys_sync(ctx, "i")

      assert editor_mode(ctx) == :normal
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "read-only")
    end

    test "SPC b m toggles the messages popup closed" do
      ctx = start_editor("hello")

      send_keys_sync(ctx, "<SPC>bm")
      screen = screen_text(ctx)
      assert String.contains?(Enum.join(screen, "\n"), "*Messages*")

      send_keys_sync(ctx, "<SPC>bm")
      screen = screen_text(ctx)
      refute String.contains?(Enum.join(screen, "\n"), "*Messages*")
    end

    test "messages buffer is hidden from the buffer picker" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bb")

      screen = screen_text(ctx)
      refute String.contains?(Enum.join(screen, "\n"), "*Messages*")
    end
  end

  describe "shared singleton semantics" do
    test "two editors share the same *Messages* content" do
      tag = unique_tag("two-editors")
      ctx_a = start_editor("a")
      ctx_b = start_editor("b")

      emit_log(tag)

      state_a = :sys.get_state(ctx_a.editor)
      state_b = :sys.get_state(ctx_b.editor)

      # Both editors read from the same singleton buffer pid, so a log
      # entry emitted once is observable through either editor's handle.
      assert String.contains?(Buffer.content(state_a.workspace.buffers.messages), tag)
      assert String.contains?(Buffer.content(state_b.workspace.buffers.messages), tag)
    end

    test "starting an editor does not start a new *Messages* buffer" do
      pid_before = Minga.Log.messages_buffer()
      assert is_pid(pid_before)

      _ctx = start_editor("hello")

      assert Minga.Log.messages_buffer() == pid_before
      assert Process.alive?(pid_before)
    end

    test "killing one editor does not kill the *Messages* buffer" do
      pid_before = Minga.Log.messages_buffer()
      assert is_pid(pid_before)
      assert Process.alive?(pid_before)

      ctx = start_editor("x")
      Process.unlink(ctx.editor)
      :ok = GenServer.stop(ctx.editor, :normal)

      assert Process.alive?(pid_before)
      assert Minga.Log.messages_buffer() == pid_before
    end

    test "entries written by one editor are visible to another" do
      tag = unique_tag("cross-editor")
      _ctx_a = start_editor("a")
      _ctx_b = start_editor("b")

      emit_log(tag)

      assert String.contains?(Buffer.content(Minga.Log.messages_buffer()), tag)
    end
  end

  describe "MessageStore dual-write" do
    # Regression coverage: external :log_message broadcasts must still
    # update the per-editor MessageStore so the GUI Messages tab keeps
    # rendering them after the singleton-buffer collapse.
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
