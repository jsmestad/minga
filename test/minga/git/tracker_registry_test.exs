defmodule Minga.Git.TrackerRegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
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

  defp assert_eventually(fun, attempts \\ 200)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        50 -> assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

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
    {:ok, buf} = BufferProcess.start_link(content: "x = 1\n", file_path: path)

    Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: path}, registry_b)
    _ = :sys.get_state(tracker)
    refute Tracker.tracked?(buf, table)

    Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: path}, registry_a)
    assert_eventually(fn -> Tracker.tracked?(buf, table) end)
  end
end
