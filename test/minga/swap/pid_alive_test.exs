defmodule Minga.Swap.PidAliveTest do
  @moduledoc "Tests for Swap.pid_alive?/1 which spawns OS processes."
  use ExUnit.Case, async: false

  alias Minga.Swap

  describe "pid_alive?/1" do
    test "returns true for the current OS process" do
      assert Swap.pid_alive?(Swap.os_pid())
    end

    test "returns false for a non-existent PID" do
      refute Swap.pid_alive?(99_999_999)
    end
  end
end
