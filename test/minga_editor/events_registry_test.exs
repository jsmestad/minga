defmodule MingaEditor.EventsRegistryTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Events

  test "editor subscribes to its configured events registry" do
    wrong_registry = :"editor_wrong_events_#{System.unique_integer([:positive])}"
    start_supervised!({Events, name: wrong_registry})
    ctx = start_editor("hello")
    wrong_tag = "wrong-registry-#{System.unique_integer([:positive])}"
    right_tag = "right-registry-#{System.unique_integer([:positive])}"

    Events.broadcast(
      :log_message,
      %Events.LogMessageEvent{text: wrong_tag, level: :info},
      wrong_registry
    )

    refute Enum.any?(message_store_entries(ctx), fn entry ->
             String.contains?(entry.text, wrong_tag)
           end)

    Events.broadcast(
      :log_message,
      %Events.LogMessageEvent{text: right_tag, level: :info},
      ctx.events_registry
    )

    assert Enum.any?(message_store_entries(ctx), fn entry ->
             String.contains?(entry.text, right_tag)
           end)
  end
end
