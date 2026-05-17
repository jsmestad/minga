defmodule MingaEditor.Frontend.ManagerTest do
  # Uses real OS ports in connected-mode tests, so serialize to avoid BEAM erl_child_setup races.
  use ExUnit.Case, async: false

  alias MingaEditor.Frontend.Manager
  alias MingaEditor.Frontend.Protocol

  defp unique_name, do: :"port_mgr_#{:erlang.unique_integer([:positive])}"

  describe "startup" do
    test "starts disconnected when renderer binary is missing" do
      name = unique_name()
      start_manager(name)

      refute Manager.ready?(name)
      assert Manager.terminal_size(name) == nil
    end
  end

  describe "send_commands/2" do
    test "returns ok when no port is open" do
      name = unique_name()
      start_manager(name)

      assert :ok = Manager.send_commands(name, [])
      assert :ok = Manager.send_commands(name, [Protocol.encode_clear()])
    end
  end

  describe "subscription behavior" do
    test "subscribers receive decoded events" do
      name = unique_name()
      pid = start_manager(name)
      :ok = Manager.subscribe(name)

      send_port_data(pid, nil, <<0x01, ?h::32, 0::8>>)

      assert_receive {:minga_input, {:key_press, ?h, 0}}
    end

    test "duplicate subscriptions receive one copy of each event" do
      name = unique_name()
      pid = start_manager(name)
      :ok = Manager.subscribe(name)
      :ok = Manager.subscribe(name)

      send_port_data(pid, nil, <<0x03, 80::16, 24::16>>)

      assert_receive {:minga_input, {:ready, 80, 24}}
      refute_receive {:minga_input, {:ready, 80, 24}}, 50
    end
  end

  describe "event handling" do
    test "ready event sets ready state and terminal size" do
      name = unique_name()
      pid = start_manager(name)
      :ok = Manager.subscribe(name)

      send_port_data(pid, nil, <<0x03, 120::16, 40::16>>)

      assert Manager.ready?(name)
      assert Manager.terminal_size(name) == {120, 40}
      assert_receive {:minga_input, {:ready, 120, 40}}
    end

    test "resize event updates terminal size" do
      name = unique_name()
      pid = start_manager(name)
      :ok = Manager.subscribe(name)

      send_port_data(pid, nil, <<0x02, 100::16, 50::16>>)

      assert Manager.terminal_size(name) == {100, 50}
      assert_receive {:minga_input, {:resize, 100, 50}}
    end

    test "malformed event data is ignored without crashing" do
      name = unique_name()
      pid = start_manager(name)

      send_port_data(pid, nil, <<0xFF, 0x01>>)

      refute Manager.ready?(name)
    end

    test "port exit clears ready state" do
      name = unique_name()
      pid = start_manager(name)

      send_port_data(pid, nil, <<0x03, 80::16, 24::16>>)
      assert Manager.ready?(name)

      send(pid, {nil, {:exit_status, 1}})

      refute Manager.ready?(name)
    end
  end

  describe "ready event replay on late subscribe" do
    test "late subscriber receives replayed ready event" do
      name = unique_name()
      pid = start_manager(name)

      send_port_data(pid, nil, <<0x03, 80::16, 24::16>>)
      assert Manager.ready?(name)

      :ok = Manager.subscribe(name)

      assert_receive {:minga_input, {:ready, 80, 24}}
    end

    test "replayed ready uses current terminal size" do
      name = unique_name()
      pid = start_manager(name)

      send_port_data(pid, nil, <<0x03, 80::16, 24::16>>)
      send_port_data(pid, nil, <<0x02, 120::16, 40::16>>)
      assert Manager.terminal_size(name) == {120, 40}

      :ok = Manager.subscribe(name)

      assert_receive {:minga_input, {:ready, 120, 40}}
      refute_receive {:minga_input, {:ready, 80, 24}}, 50
    end

    test "no spurious ready when port is not yet ready" do
      name = unique_name()
      start_manager(name)

      :ok = Manager.subscribe(name)

      refute_receive {:minga_input, {:ready, _, _}}, 50
    end

    test "late subscriber in connected mode receives replayed ready" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)

      send_port_data(pid, fake_port, <<0x03, 80::16, 24::16>>)
      assert Manager.ready?(name)

      :ok = Manager.subscribe(name)

      assert_receive {:minga_input, {:ready, 80, 24}}
    end

    test "no replay after port EOF clears ready state" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)

      send_port_data(pid, fake_port, <<0x03, 80::16, 24::16>>)
      assert Manager.ready?(name)
      send(pid, {fake_port, :eof})
      refute Manager.ready?(name)

      :ok = Manager.subscribe(name)

      refute_receive {:minga_input, {:ready, _, _}}, 50
    end
  end

  describe "unknown messages" do
    test "unknown messages are ignored" do
      name = unique_name()
      pid = start_manager(name)

      send(pid, :totally_unknown)

      refute Manager.ready?(name)
    end
  end

  describe "connected mode" do
    test "starts successfully in connected mode" do
      name = unique_name()
      {_pid, _fake_port} = start_connected(name)

      refute Manager.ready?(name)
    end

    test "connected mode opens stdin/stdout with eof handling" do
      name = unique_name()
      test_pid = self()

      capturing_opener = fn spec, opts ->
        send(test_pid, {:port_open_args, spec, opts})
        Port.open({:spawn, "cat 2>/dev/null"}, [:binary, {:packet, 4}])
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

    test "protocol events work identically in connected mode" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)
      :ok = Manager.subscribe(name)

      send_port_data(pid, fake_port, <<0x03, 80::16, 24::16>>)

      assert Manager.ready?(name)
      assert Manager.terminal_size(name) == {80, 24}
      assert_receive {:minga_input, {:ready, 80, 24}}

      send_port_data(pid, fake_port, <<0x01, ?j::32, 0::8>>)

      assert_receive {:minga_input, {:key_press, ?j, 0}}
    end

    test "EOF on connected port clears ready state" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)
      :ok = Manager.subscribe(name)

      send_port_data(pid, fake_port, <<0x03, 80::16, 24::16>>)
      assert Manager.ready?(name)

      send(pid, {fake_port, :eof})

      refute Manager.ready?(name)
    end

    test "double EOF and send_commands after EOF are harmless" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)

      send(pid, {fake_port, :eof})
      refute Manager.ready?(name)

      send(pid, {fake_port, :eof})
      assert :ok = Manager.send_commands(name, [Protocol.encode_clear()])
    end

    test "send_commands works when connected" do
      name = unique_name()
      {_pid, _fake_port} = start_connected(name)

      assert :ok = Manager.send_commands(name, [Protocol.encode_clear()])
    end
  end

  defp start_manager(name) do
    start_supervised!({Manager, name: name, renderer_path: "/nonexistent"}, id: name)
  end

  defp send_port_data(pid, port, payload) do
    send(pid, {port, {:data, payload}})
  end

  defp fake_port_opener do
    test_pid = self()

    fn _spec, _opts ->
      port = Port.open({:spawn, "cat 2>/dev/null"}, [:binary, {:packet, 4}])
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
end
