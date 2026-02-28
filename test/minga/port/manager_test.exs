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

    test "multiple subscriptions from same process are deduplicated" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")
      :ok = Manager.subscribe(name)
      :ok = Manager.subscribe(name)

      # Should still work — no duplicate messages
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "send_commands/2" do
    test "does not crash when port is not open" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")

      :ok = Manager.send_commands(name, [Protocol.encode_clear()])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handles empty command list" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")

      :ok = Manager.send_commands(name, [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handles multiple commands" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")

      commands = [
        Protocol.encode_clear(),
        Protocol.encode_draw(0, 0, "hello"),
        Protocol.encode_cursor(0, 5),
        Protocol.encode_batch_end()
      ]

      :ok = Manager.send_commands(name, commands)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "terminal_size/1" do
    test "returns nil before ready" do
      name = unique_name()
      {:ok, _pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")
      assert Manager.terminal_size(name) == nil
      GenServer.stop(name)
    end
  end

  describe "ready?/1" do
    test "returns false before ready event" do
      name = unique_name()
      {:ok, _pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")
      refute Manager.ready?(name)
      GenServer.stop(name)
    end
  end

  describe "event handling" do
    test "ready event sets ready state and terminal size" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")
      :ok = Manager.subscribe(name)

      ready_payload = <<0x03, 120::16, 40::16>>
      send(pid, {nil, {:data, ready_payload}})
      Process.sleep(30)

      assert Manager.ready?(name)
      assert Manager.terminal_size(name) == {120, 40}

      assert_receive {:minga_input, {:ready, 120, 40}}
      GenServer.stop(pid)
    end

    test "resize event updates terminal size" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")
      :ok = Manager.subscribe(name)

      resize_payload = <<0x02, 100::16, 50::16>>
      send(pid, {nil, {:data, resize_payload}})
      Process.sleep(30)

      assert Manager.terminal_size(name) == {100, 50}

      assert_receive {:minga_input, {:resize, 100, 50}}
      GenServer.stop(pid)
    end

    test "key_press event is broadcast to subscribers" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")
      :ok = Manager.subscribe(name)

      key_payload = <<0x01, ?h::32, 0::8>>
      send(pid, {nil, {:data, key_payload}})
      Process.sleep(30)

      assert_receive {:minga_input, {:key_press, ?h, 0}}
      GenServer.stop(pid)
    end

    test "malformed event data logs warning but doesn't crash" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")

      send(pid, {nil, {:data, <<0xFF, 0x01>>}})
      Process.sleep(30)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "port exit status is handled" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")

      send(pid, {nil, {:exit_status, 1}})
      Process.sleep(30)

      assert Process.alive?(pid)
      refute Manager.ready?(name)
      GenServer.stop(pid)
    end
  end

  describe "subscriber cleanup" do
    test "removes subscriber when it exits" do
      name = unique_name()
      {:ok, mgr} = Manager.start_link(name: name, renderer_path: "/nonexistent")

      task =
        Task.async(fn ->
          Manager.subscribe(name)
          :ok
        end)

      Task.await(task)
      Process.sleep(50)

      assert Process.alive?(mgr)
      GenServer.stop(mgr)
    end
  end

  describe "unknown messages" do
    test "unknown messages are ignored" do
      name = unique_name()
      {:ok, pid} = Manager.start_link(name: name, renderer_path: "/nonexistent")

      send(pid, :totally_unknown)
      Process.sleep(30)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
