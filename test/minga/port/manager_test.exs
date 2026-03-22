defmodule Minga.Port.ManagerTest do
  use ExUnit.Case, async: true

  alias Minga.Port.Manager
  alias Minga.Port.Protocol

  defp unique_name, do: :"port_mgr_#{:erlang.unique_integer([:positive])}"

  describe "start_link/1" do
    test "starts with a custom name" do
      name = unique_name()
      pid = start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      _ = :sys.get_state(pid)
    end

    test "starts without crashing when renderer binary is missing" do
      name = unique_name()
      start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      refute Manager.ready?(name)
      assert Manager.terminal_size(name) == nil
    end
  end

  describe "subscribe/1" do
    test "subscribing process receives events" do
      name = unique_name()
      pid = start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      :ok = Manager.subscribe(name)

      ready_payload = <<0x03, 80::16, 24::16>>
      send(pid, {nil, {:data, ready_payload}})
      _ = :sys.get_state(pid)

      assert_receive {:minga_input, {:ready, 80, 24}}
    end

    test "multiple subscriptions from same process are deduplicated" do
      name = unique_name()
      start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      :ok = Manager.subscribe(name)
      :ok = Manager.subscribe(name)

      state = :sys.get_state(name)
      assert length(state.subscribers) == 1
    end
  end

  describe "send_commands/2" do
    test "does not crash when port is not open" do
      name = unique_name()
      start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      :ok = Manager.send_commands(name, [Protocol.encode_clear()])
    end

    test "handles empty command list" do
      name = unique_name()
      start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      :ok = Manager.send_commands(name, [])
    end

    test "handles multiple commands" do
      name = unique_name()
      start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)

      commands = [
        Protocol.encode_clear(),
        Protocol.encode_draw(0, 0, "hello"),
        Protocol.encode_cursor(0, 5),
        Protocol.encode_batch_end()
      ]

      :ok = Manager.send_commands(name, commands)
    end
  end

  describe "terminal_size/1" do
    test "returns nil before ready" do
      name = unique_name()
      start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      assert Manager.terminal_size(name) == nil
    end
  end

  describe "ready?/1" do
    test "returns false before ready event" do
      name = unique_name()
      start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      refute Manager.ready?(name)
    end
  end

  describe "event handling" do
    test "ready event sets ready state and terminal size" do
      name = unique_name()
      pid = start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      :ok = Manager.subscribe(name)

      ready_payload = <<0x03, 120::16, 40::16>>
      send(pid, {nil, {:data, ready_payload}})
      _ = :sys.get_state(pid)

      assert Manager.ready?(name)
      assert Manager.terminal_size(name) == {120, 40}
      assert_receive {:minga_input, {:ready, 120, 40}}
    end

    test "resize event updates terminal size" do
      name = unique_name()
      pid = start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      :ok = Manager.subscribe(name)

      resize_payload = <<0x02, 100::16, 50::16>>
      send(pid, {nil, {:data, resize_payload}})
      _ = :sys.get_state(pid)

      assert Manager.terminal_size(name) == {100, 50}
      assert_receive {:minga_input, {:resize, 100, 50}}
    end

    test "key_press event is broadcast to subscribers" do
      name = unique_name()
      pid = start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
      :ok = Manager.subscribe(name)

      key_payload = <<0x01, ?h::32, 0::8>>
      send(pid, {nil, {:data, key_payload}})
      _ = :sys.get_state(pid)

      assert_receive {:minga_input, {:key_press, ?h, 0}}
    end

    test "malformed event data logs warning but doesn't crash" do
      name = unique_name()
      pid = start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)

      send(pid, {nil, {:data, <<0xFF, 0x01>>}})
      _ = :sys.get_state(pid)
    end

    test "port exit status is handled" do
      name = unique_name()
      pid = start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)

      send(pid, {nil, {:exit_status, 1}})
      _ = :sys.get_state(pid)

      refute Manager.ready?(name)
    end
  end

  describe "subscriber cleanup" do
    test "removes subscriber when it exits" do
      name = unique_name()
      mgr = start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)

      task =
        Task.async(fn ->
          Manager.subscribe(name)
          :ok
        end)

      Task.await(task)
      _ = :sys.get_state(mgr)
    end
  end

  describe "unknown messages" do
    test "unknown messages are ignored" do
      name = unique_name()
      pid = start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)

      send(pid, :totally_unknown)
      _ = :sys.get_state(pid)
    end
  end

  # Helper that creates a fake port for connected mode tests.
  # Uses `cat` as a harmless process so Port.command doesn't crash.
  defp fake_port_opener do
    test_pid = self()

    fn _spec, _opts ->
      port = Port.open({:spawn, "cat"}, [:binary, {:packet, 4}])
      send(test_pid, {:fake_port, port})
      port
    end
  end

  defp start_connected(name) do
    opener = fake_port_opener()

    pid =
      start_supervised!(
        {Manager,
         name: name, renderer_path: "/nonexistent", port_mode: :connected, port_opener: opener},
        id: name
      )

    assert_receive {:fake_port, fake_port}
    {pid, fake_port}
  end

  describe "connected mode" do
    test "starts successfully in connected mode" do
      name = unique_name()
      {_pid, _fake_port} = start_connected(name)

      refute Manager.ready?(name)
    end

    test "connected mode opens port with {:fd, 0, 1} and :eof option" do
      name = unique_name()
      test_pid = self()

      capturing_opener = fn spec, opts ->
        send(test_pid, {:port_open_args, spec, opts})
        Port.open({:spawn, "cat"}, [:binary, {:packet, 4}])
      end

      start_supervised!(
        {Manager,
         name: name,
         renderer_path: "/nonexistent",
         port_mode: :connected,
         port_opener: capturing_opener},
        id: name
      )

      assert_receive {:port_open_args, {:fd, 0, 1}, opts}
      assert :binary in opts
      assert {:packet, 4} in opts
      assert :eof in opts
    end

    test "port_mode option is stored in state" do
      name = unique_name()

      # Explicitly passing :spawn should set port_mode regardless of any config
      pid =
        start_supervised!(
          {Manager, name: name, renderer_path: "/nonexistent", port_mode: :spawn},
          id: name
        )

      state = :sys.get_state(pid)
      assert state.port_mode == :spawn
    end

    test "protocol events work identically in connected mode" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)
      :ok = Manager.subscribe(name)

      # Ready event
      ready_payload = <<0x03, 80::16, 24::16>>
      send(pid, {fake_port, {:data, ready_payload}})
      _ = :sys.get_state(pid)

      assert Manager.ready?(name)
      assert Manager.terminal_size(name) == {80, 24}
      assert_receive {:minga_input, {:ready, 80, 24}}

      # Key press event
      key_payload = <<0x01, ?j::32, 0::8>>
      send(pid, {fake_port, {:data, key_payload}})
      _ = :sys.get_state(pid)

      assert_receive {:minga_input, {:key_press, ?j, 0}}
    end

    test "EOF on connected port clears ready state" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)
      :ok = Manager.subscribe(name)

      # Set ready state first
      ready_payload = <<0x03, 80::16, 24::16>>
      send(pid, {fake_port, {:data, ready_payload}})
      _ = :sys.get_state(pid)
      assert Manager.ready?(name)

      # Simulate stdin EOF (GUI parent exited)
      send(pid, {fake_port, :eof})
      _ = :sys.get_state(pid)

      refute Manager.ready?(name)
    end

    test "double EOF does not crash" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)

      send(pid, {fake_port, :eof})
      _ = :sys.get_state(pid)

      # Second EOF: port is nil, message won't match the port guard
      send(pid, {fake_port, :eof})
      # Process should still be alive (sync barrier confirms)
      _ = :sys.get_state(pid)
    end

    test "send_commands works in connected mode" do
      name = unique_name()
      {_pid, _fake_port} = start_connected(name)

      # Should not crash (port is open via fake_port_opener)
      :ok = Manager.send_commands(name, [Protocol.encode_clear()])
    end

    test "send_commands after EOF silently drops commands" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)

      send(pid, {fake_port, :eof})
      _ = :sys.get_state(pid)

      # Port is nil now, commands should be silently dropped
      :ok = Manager.send_commands(name, [Protocol.encode_clear()])
    end

    test "port_mode defaults to :spawn when no option is passed" do
      name = unique_name()

      # Without passing port_mode, and with no app config set (test env default),
      # it should default to :spawn
      pid =
        start_supervised!(
          {Manager, name: name, renderer_path: "/nonexistent"},
          id: name
        )

      state = :sys.get_state(pid)
      assert state.port_mode == :spawn
    end
  end
end
