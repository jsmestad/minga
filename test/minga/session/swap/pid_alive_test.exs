defmodule Minga.Session.Swap.PidAliveTest do
  @moduledoc "Tests for the `Minga.Session.Swap` functions that ask the OS about a process, which spawns `ps` on macOS."

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
      # The OS process that started this VM is alive for as long as the test runs.
      parent = parent_pid()
      {:ok, started} = Instance.start_time(parent)

      assert Swap.owner_alive?(%{os_pid: parent, run_started: started})
      refute Swap.owner_alive?(%{os_pid: parent, run_started: "Thu Jan  1 00:00:00 1970"})
      refute Swap.owner_alive?(%{os_pid: 99_999_999, run_started: started})
    end
  end

  defp parent_pid do
    {output, 0} = System.cmd("ps", ["-p", Integer.to_string(Swap.os_pid()), "-o", "ppid="])
    output |> String.trim() |> String.to_integer()
  end
end
