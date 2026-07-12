defmodule MingaEditor.MessagesBufferTest do
  @moduledoc """
  Editor-facing smoke coverage for external log delivery.

  Message buffer lifecycle, bottom-panel commands, and input routing are covered at their owning boundaries.
  """

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  test "external broadcasts append to the editor MessageStore" do
    tag = "msgtest-#{System.unique_integer([:positive])}"
    ctx = start_editor("hello")

    Minga.Events.broadcast(
      :log_message,
      %Minga.Events.LogMessageEvent{text: tag, level: :warning},
      ctx.events_registry
    )

    assert Enum.any?(message_store_entries(ctx), fn entry ->
             String.contains?(entry.text, tag) and entry.level == :warning
           end)
  end
end
