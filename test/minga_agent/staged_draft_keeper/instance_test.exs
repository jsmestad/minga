defmodule MingaAgent.StagedDraftKeeper.InstanceTest do
  # Every check runs `ps`, an OS process; async OS spawns hit the
  # erl_child_setup EPIPE race.
  use ExUnit.Case, async: false

  alias MingaAgent.StagedDraftKeeper.Instance

  @moduletag timeout: 10_000

  test "this instance is alive" do
    instance = Instance.current()

    assert instance.os_pid == String.to_integer(System.pid())
    assert Instance.alive?(instance)
  end

  test "a reused process id with another start time is not the recorded instance" do
    refute Instance.alive?(%{Instance.current() | started: "Thu Jan  1 00:00:00 1970"})
  end

  test "an exited process is gone" do
    refute Instance.alive?(%{os_pid: 2_147_483_000, started: "Thu Jan  1 00:00:00 1970"})
  end
end
