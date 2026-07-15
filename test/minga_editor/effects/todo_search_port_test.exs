defmodule MingaEditor.Effects.TodoSearch.PortTest do
  # These tests spawn real OS Ports and compare the VM's global Port inventory.
  use ExUnit.Case, async: false

  alias MingaEditor.Effects.TodoSearch.Port, as: TodoSearchPort

  @moduletag :heavy

  test "uses an absolute five-second deadline despite intermittent output" do
    ports_before = MapSet.new(Port.list())
    started_at = System.monotonic_time(:millisecond)

    command = "printf 'started\\n'; sleep 4; printf 'still-running\\n'; exec sleep 60"
    assert TodoSearchPort.run("sh", ["-c", command]) == {"command timed out", 124}

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms >= 4_500
    assert elapsed_ms < 8_000
    assert MapSet.difference(MapSet.new(Port.list()), ports_before) == MapSet.new()
  end

  test "closes the Port before retaining output beyond the total byte ceiling" do
    ports_before = MapSet.new(Port.list())

    assert TodoSearchPort.run("sh", ["-c", "head -c 9000000 /dev/zero"]) ==
             {"command output exceeded 8388608 bytes", 125}

    assert MapSet.difference(MapSet.new(Port.list()), ports_before) == MapSet.new()
  end
end
