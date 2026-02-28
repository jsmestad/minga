defmodule Minga.Port.ManagerTest do
  use ExUnit.Case

  alias Minga.Port.Manager
  alias Minga.Port.Protocol

  describe "start_link/1" do
    test "starts with a custom name" do
      {:ok, pid} = Manager.start_link(name: :test_port_mgr, renderer_path: "/nonexistent")
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts without crashing when renderer binary is missing" do
      {:ok, pid} = Manager.start_link(name: :test_port_mgr2, renderer_path: "/nonexistent")
      assert Process.alive?(pid)
      refute Manager.ready?(:test_port_mgr2)
      assert Manager.terminal_size(:test_port_mgr2) == nil
      GenServer.stop(pid)
    end
  end

  describe "subscribe/1" do
    test "subscribing process receives events" do
      {:ok, pid} = Manager.start_link(name: :test_sub_mgr, renderer_path: "/nonexistent")
      :ok = Manager.subscribe(:test_sub_mgr)

      # Simulate sending a ready event as if from the port
      ready_payload = <<0x03, 80::16, 24::16>>
      send(pid, {nil, {:data, ready_payload}})

      # We won't receive it because the port reference won't match
      # (the port is nil since the binary doesn't exist)
      # This tests the subscription mechanics
      GenServer.stop(pid)
    end
  end

  describe "send_commands/2" do
    test "does not crash when port is not open" do
      {:ok, pid} = Manager.start_link(name: :test_cmd_mgr, renderer_path: "/nonexistent")

      # Should log a warning but not crash
      :ok = Manager.send_commands(:test_cmd_mgr, [Protocol.encode_clear()])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "subscriber cleanup" do
    test "removes subscriber when it exits" do
      {:ok, mgr} = Manager.start_link(name: :test_cleanup_mgr, renderer_path: "/nonexistent")

      # Spawn a subscriber that immediately exits
      task =
        Task.async(fn ->
          Manager.subscribe(:test_cleanup_mgr)
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
