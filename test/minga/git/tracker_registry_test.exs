defmodule Minga.Git.TrackerRegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Events
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Git.Tracker

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    GitStub.set_root(dir, dir)
    on_exit(fn -> GitStub.clear(dir) end)
    %{root: dir}
  end

  defp start_registry(label) do
    name = :"#{label}_#{System.unique_integer([:positive])}"
    start_supervised!({Events, name: name})
    name
  end

  test "tracker starts tracking only for events from its configured registry", %{root: dir} do
    registry_a = start_registry(:tracker_events_a)
    registry_b = start_registry(:tracker_events_b)
    table = :"tracker_registry_#{System.unique_integer([:positive])}"
    tracker_name = :"tracker_#{System.unique_integer([:positive])}"

    tracker =
      start_supervised!(
        {Tracker, name: tracker_name, events_registry: registry_a, registry_table: table},
        id: table
      )

    path = Path.join(dir, "tracker_registry_test.ex")
    File.write!(path, "x = 1\n")
    GitStub.set_head(dir, Path.relative_to(path, dir), "x = 1\n")
    {:ok, buf} = BufferServer.start_link(content: "x = 1\n", file_path: path)

    Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: path}, registry_b)
    _ = :sys.get_state(tracker)
    refute Tracker.tracked?(buf, table)

    Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: path}, registry_a)
    _ = :sys.get_state(tracker)
    assert Tracker.tracked?(buf, table)
  end
end
