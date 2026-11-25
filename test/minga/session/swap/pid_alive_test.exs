defmodule Minga.Session.Swap.PidAliveTest do
  @moduledoc "Tests for the `Minga.Session.Swap` functions that ask the OS about a process, which spawns `ps`."

  # Spawns an OS process (`ps`); concurrent spawns hit the BEAM's erl_child_setup EPIPE race.
  use ExUnit.Case, async: false

  alias Minga.Session.Swap

  describe "pid_alive?/1" do
    test "returns true for the current OS process" do
      assert Swap.pid_alive?(Swap.os_pid())
    end

    test "returns false for a non-existent PID" do
      refute Swap.pid_alive?(99_999_999)
    end
  end

  describe "process_state/1" do
    test "the start the OS reports for this VM matches the start this VM records for its swaps" do
      # Another editor decides whether this run is alive by this comparison, so it has to hold.
      assert {:running, started} = Swap.process_state(Swap.os_pid())
      assert_in_delta started, Swap.run_started(), 5
    end

    test "a process id nothing runs under is gone" do
      assert Swap.process_state(99_999_999) == :gone
    end
  end

  describe "owner_alive?/1 with the real probe" do
    test "a swap written for this VM's parent process is owned while that process runs" do
      # The OS process that started this VM is alive for as long as the test runs.
      parent = parent_pid()
      {:running, started} = Swap.process_state(parent)

      assert Swap.owner_alive?(%{os_pid: parent, run_started: started})
      refute Swap.owner_alive?(%{os_pid: parent, run_started: started - 3_600})
    end
  end

  defp parent_pid do
    {output, 0} = System.cmd("ps", ["-p", Integer.to_string(Swap.os_pid()), "-o", "ppid="])
    output |> String.trim() |> String.to_integer()
  end
end
