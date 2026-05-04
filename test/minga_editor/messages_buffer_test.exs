defmodule MingaEditor.MessagesBufferTest do
  @moduledoc """
  Tests for the *Messages* buffer popup and `SPC b m`.

  The `*Messages*` buffer is now a BEAM-wide singleton owned by
  `Minga.Buffer.Messages` (#1483). Each test owns a unique tag it
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
    _ = :sys.get_state(Minga.Buffer.Messages)
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

      assert String.contains?(Buffer.content(Buffer.messages()), tag)
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
    test "Minga.Buffer.messages/0 returns the same pid across editors" do
      pid_before = Buffer.messages()
      assert is_pid(pid_before)

      ctx_a = start_editor("a")
      ctx_b = start_editor("b")

      state_a = :sys.get_state(ctx_a.editor)
      state_b = :sys.get_state(ctx_b.editor)

      assert state_a.workspace.buffers.messages == pid_before
      assert state_b.workspace.buffers.messages == pid_before
    end

    test "killing one editor does not kill the *Messages* buffer" do
      pid_before = Buffer.messages()
      assert is_pid(pid_before)
      assert Process.alive?(pid_before)

      ctx = start_editor("x")
      Process.unlink(ctx.editor)
      :ok = GenServer.stop(ctx.editor, :normal)

      assert Process.alive?(pid_before)
      assert Buffer.messages() == pid_before
    end

    test "entries written by one editor are visible to another" do
      tag = unique_tag("cross-editor")
      _ctx_a = start_editor("a")
      _ctx_b = start_editor("b")

      emit_log(tag)

      assert String.contains?(Buffer.content(Buffer.messages()), tag)
    end
  end
end
