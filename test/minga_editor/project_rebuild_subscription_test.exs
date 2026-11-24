defmodule MingaEditor.ProjectRebuildSubscriptionTest do
  use Minga.Test.EditorCase, async: true

  test "the Editor listens for both rebuild outcomes so an open file picker never waits on a failed rebuild" do
    ctx = start_editor("hello")

    for topic <- [:project_rebuilt, :project_rebuild_failed] do
      assert ctx.editor in Minga.Events.subscribers(topic, ctx.events_registry)
    end
  end
end
