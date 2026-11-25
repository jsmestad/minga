defmodule Minga.Session.InstanceTest do
  # Every check runs `ps`, an OS process; async OS spawns hit the
  # erl_child_setup EPIPE race.
  use ExUnit.Case, async: false

  alias Minga.Session.Instance

  @moduletag timeout: 10_000

  test "this instance is alive" do
    instance = Instance.current()

    assert instance.os_pid == String.to_integer(System.pid())
    assert Instance.alive?(instance)
  end

  test "the identity reads the same in every time zone" do
    tokyo = Instance.current([{"TZ", "Asia/Tokyo"}])

    assert Instance.current([{"TZ", "America/Denver"}]) == tokyo
    assert Instance.alive?(tokyo, [{"TZ", "America/Denver"}])
  end

  test "a reused process id with another start time is not the recorded instance" do
    refute Instance.alive?(%{Instance.current() | started: "Thu Jan  1 00:00:00 1970"})
  end

  test "an exited process is gone" do
    refute Instance.alive?(%{os_pid: 2_147_483_000, started: "Thu Jan  1 00:00:00 1970"})
  end

  test "a zombie has exited, so it is not the recorded instance" do
    # `ps -o stat= -o lstart=` prints the state letters, then the start time.
    assert Instance.parse_ps("Ss   Tue Nov 24 20:27:02 2026    \n") ==
             {:ok, "Tue Nov 24 20:27:02 2026"}

    assert Instance.parse_ps("Z    Tue Nov 24 20:27:02 2026\n") == :error
    assert Instance.parse_ps("Z+   Tue Nov 24 20:27:02 2026\n") == :error
    assert Instance.parse_ps("") == :error
  end

  test "the start time of a process is the one its instance records" do
    %{os_pid: os_pid, started: started} = Instance.current()

    assert Instance.start_time(os_pid) == {:ok, started}
    assert Instance.start_time(2_147_483_000) == :error
  end
end
