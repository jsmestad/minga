defmodule Minga.Session.Swap.PidAliveTest do
  @moduledoc "Tests for the `Minga.Session.Swap` functions that ask the OS about a process: `/proc` on Linux, `ps` on macOS."

  # Spawns an OS process (`ps`); concurrent spawns hit the BEAM's erl_child_setup EPIPE race.
  use ExUnit.Case, async: false

  alias Minga.Session.Instance
  alias Minga.Session.Swap

  describe "pid_alive?/1" do
    test "returns true for the current OS process" do
      assert Swap.pid_alive?(Swap.os_pid())
    end

    test "returns false for a non-existent PID" do
      refute Swap.pid_alive?(99_999_999)
      refute Swap.pid_alive?(0)
    end
  end

  describe "this_run/0" do
    test "is what the OS reports for this VM now, so another editor recognizes this run as alive" do
      assert Swap.this_run() == Instance.current()
      assert Instance.alive?(Swap.this_run())
    end
  end

  describe "owner_alive?/1 with the real start time" do
    test "a swap of another live process is owned only with that process's own start time" do
      # Process 1 (launchd, init, or a container's entry point) runs for as long as the test does.
      {:ok, started} = Instance.start_time(1)

      assert Swap.owner_alive?(%{os_pid: 1, run_started: started})
      refute Swap.owner_alive?(%{os_pid: 1, run_started: "Thu Jan  1 00:00:00 1970"})
      refute Swap.owner_alive?(%{os_pid: 99_999_999, run_started: started})
    end

    test "a swap from before the start time was recorded is kept while its process id is in use" do
      assert Swap.owner_alive?(%{os_pid: 1, run_started: nil})
      refute Swap.owner_alive?(%{os_pid: 99_999_999, run_started: nil})
    end
  end
end
