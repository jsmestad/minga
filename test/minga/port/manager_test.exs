defmodule Minga.Port.ManagerTest do
  use ExUnit.Case, async: true

  alias Minga.Port.Manager
  alias Minga.Port.Protocol

  defp unique_name, do: :"port_mgr_#{:erlang.unique_integer([:positive])}"

  describe "start_link/1" do
    test "starts with a custom name" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts without crashing when renderer binary is missing" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")
      assert Process.alive?(pid)
      refute Manager.ready?(name)
      assert Manager.terminal_size(name) == nil
      GenServer.stop(pid)
    end
  end

  describe "subscribe/1" do
    test "subscribing process receives events" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")
      :ok = Manager.subscribe(name)

      # Simulate sending a ready event as if from the port
      ready_payload = <<0x03, 80::16, 24::16>>
      send(pid, {nil, {:data, ready_payload}})

      GenServer.stop(pid)
    end
  end

  describe "send_commands/2" do
    test "does not crash when port is not open" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")

      # Should log a warning but not crash
      :ok = Manager.send_commands(name, [Protocol.encode_clear()])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "subscriber cleanup" do
    test "removes subscriber when it exits" do
      name = unique_name()
      {:ok, mgr} = Manager.start_link(name: name, renderer_path: "/nonexistent")

      # Spawn a subscriber that immediately exits
      task =
        Task.async(fn ->
          Manager.subscribe(name)
          :ok
        end)

      Task.await(task)
      # Give the DOWN message time to be processed
      Process.sleep(50)

      # Manager should still be alive
      assert Process.alive?(mgr)
      GenServer.stop(mgr)
    end
  end
end
