defmodule MingaEditor.Frontend.ManagerTest do
  # Connected-mode tests use real OS ports, so this mixed module remains serialized.
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

    @tag :heavy
    test "spawn mode opens renderer executable with tty env" do
      name = unique_name()

      renderer_path =
        Path.join(System.tmp_dir!(), "minga-renderer-go-#{System.unique_integer([:positive])}")

      File.write!(renderer_path, "")
      parent = self()

      on_exit(fn ->
        File.rm(renderer_path)
      end)

      capturing_opener = fn spec, opts ->
        send(parent, {:port_open_args, spec, opts})
        Port.open({:spawn, "cat 2>/dev/null"}, [:binary, {:packet, 4}])
      end

      start_supervised!(
        {Manager,
         name: name,
         renderer_path: renderer_path,
         port_opener: capturing_opener,
         tty_path: "/dev/tty"},
        id: name
      )

      assert_receive {:port_open_args, {:spawn_executable, ^renderer_path}, opts}
      assert :binary in opts
      assert :use_stdio in opts
      assert {:packet, 4} in opts
      assert {:env, [{~c"MINGA_TTY", ~c"/dev/tty"}]} in opts
    end
  end

  describe "send_commands/2" do
    test "returns unwritable when no port is open" do
      name = unique_name()
      start_manager(name)

      assert :unwritable = Manager.send_commands(name, [])
      assert :unwritable = Manager.send_commands(name, [Protocol.encode_commit_frame(0)])
    end
  end

  describe "subscription behavior" do
    test "subscribers receive decoded events" do
      name = unique_name()
      pid = start_manager(name)
      :ok = Manager.subscribe(name)

      send_port_data(pid, nil, <<0x01, ?h::32, 0::8>>)

      assert_receive {:minga_input, {:key_press, ?h, 0, 0}}
    end

    test "request_keyframe is routed opaquely to subscribers (#2219)" do
      name = unique_name()
      pid = start_manager(name)
      :ok = Manager.subscribe(name)

      # opcode 0x08 + last_good_frame_seq:u32 + generation:u32. The Manager stays opaque transport
      # and only broadcasts the decoded event; the BEAM owns keyframe forcing.
      send_port_data(pid, nil, <<0x08, 42::32, 7::32>>)

      assert_receive {:minga_input, {:request_keyframe, 42, 7}}
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

    test "versioned ready with the matching protocol_version becomes ready" do
      name = unique_name()
      pid = start_manager(name)
      :ok = Manager.subscribe(name)

      version = Minga.Protocol.Opcodes.protocol_version()
      # 7 caps fields (native GUI) then the u16 protocol_version tail.
      ready = <<0x03, 120::16, 40::16, 1, 7, 1, 2, 1, 3, 1, 1, 1, version::16>>
      send_port_data(pid, nil, ready)

      assert Manager.ready?(name)
      assert Manager.terminal_size(name) == {120, 40}
      assert_receive {:minga_input, {:ready, 120, 40}}
    end

    test "ready with a mismatched protocol_version stays not ready (no silent desync)" do
      name = unique_name()
      pid = start_manager(name)
      :ok = Manager.subscribe(name)

      bad = Minga.Protocol.Opcodes.protocol_version() + 99
      ready = <<0x03, 120::16, 40::16, 1, 7, 1, 2, 1, 3, 1, 1, 1, bad::16>>
      send_port_data(pid, nil, ready)

      refute Manager.ready?(name)
      refute_receive {:minga_input, {:ready, 120, 40}}, 50
    end

    test "legacy unversioned extended ready is rejected (protocol_version 0)" do
      name = unique_name()
      pid = start_manager(name)

      # Extended ready with no version tail decodes as protocol_version 0.
      send_port_data(pid, nil, <<0x03, 120::16, 40::16, 1, 7, 1, 2, 1, 3, 1, 1, 1>>)

      refute Manager.ready?(name)
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

    @tag :heavy
    test "late subscriber in connected mode receives replayed ready" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)

      send_port_data(pid, fake_port, <<0x03, 80::16, 24::16>>)
      assert Manager.ready?(name)

      :ok = Manager.subscribe(name)

      assert_receive {:minga_input, {:ready, 80, 24}}
    end

    @tag :heavy
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

  describe "output pressure" do
    test "unwritable transport requests correlated keyframe recovery and rejects stale acknowledgements" do
      name = unique_name()
      commander = fn _port, _batch, [:nosuspend] -> false end

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 1,
          output_failure_ms: 0
        )

      :ok = Manager.subscribe(name)
      send_port_data(pid, fake_port, <<0x0A, 1::32, 10::32>>)
      assert_receive {:minga_input, {:frame_applied, 1, 10}}

      assert :unwritable = Manager.send_render_commands(name, frame_commands(11, 10, 1))
      assert_receive {:minga_input, {:request_keyframe, 10, 1}}, 1_000

      send_port_data(pid, fake_port, <<0x0A, 1::32, 11::32>>)
      refute_receive {:minga_input, {:frame_applied, 1, 11}}, 50

      send_port_data(pid, fake_port, <<0x0A, 2::32, 12::32>>)
      assert_receive {:minga_input, {:frame_applied, 2, 12}}

      pressure = Manager.output_pressure(name)
      assert pressure.minimum_ack_generation == 2
      assert pressure.last_applied_generation == 2
      assert pressure.last_applied_frame_seq == 12
      assert pressure.retained_bytes == 0
    end

    test "an unwritable font configuration is retained and retried before later frames" do
      name = unique_name()
      parent = self()
      outcomes = start_supervised!({Agent, fn -> [false, true] end}, id: make_ref())

      commander = fn _port, batch, [:nosuspend] ->
        outcome =
          Agent.get_and_update(outcomes, fn
            [next | rest] -> {next, rest}
            [] -> {true, []}
          end)

        send(parent, {:font_control_attempt, outcome, batch})
        outcome
      end

      {_pid, _fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 20,
          output_failure_ms: 1_000
        )

      font_command = Protocol.encode_set_font("Fira Code", 15, true, :regular)
      assert :unwritable = Manager.send_commands(name, [font_command])
      assert_receive {:font_control_attempt, false, ^font_command}

      pressure = Manager.output_pressure(name)
      assert pressure.control_batches == 1
      assert pressure.control_bytes == byte_size(font_command)

      assert_receive {:font_control_attempt, true, ^font_command}, 1_000
      pressure = Manager.output_pressure(name)
      assert pressure.control_batches == 0
      assert pressure.control_bytes == 0
    end

    test "an incompatible coalesced replacement triggers keyframe recovery instead of skipping its base" do
      name = unique_name()
      outcomes = start_supervised!({Agent, fn -> [false, true] end}, id: make_ref())

      commander = fn _port, _batch, [:nosuspend] ->
        Agent.get_and_update(outcomes, fn
          [outcome | rest] -> {outcome, rest}
          [] -> {true, []}
        end)
      end

      {_pid, _fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 20,
          output_failure_ms: 1_000
        )

      :ok = Manager.subscribe(name)
      assert :unwritable = Manager.send_render_commands(name, frame_commands(10, 9, 1))
      assert :unwritable = Manager.send_render_commands(name, frame_commands(12, 11, 1))
      assert_receive {:minga_input, {:request_keyframe, 0, 1}}, 1_000

      pressure = Manager.output_pressure(name)
      assert pressure.minimum_ack_generation == 2
      assert pressure.retained_bytes == 0
    end

    @tag :heavy
    test "a frontend that stops reading retains at most two frames and keeps input responsive" do
      name = unique_name()
      parent = self()

      opener = fn _spec, _opts ->
        port = Port.open({:spawn, "sleep 10"}, [:binary, {:packet, 4}])
        send(parent, {:pressure_port, port})
        port
      end

      pid =
        start_supervised!(
          {Manager,
           name: name,
           renderer_path: "/nonexistent",
           port_mode: :connected,
           port_opener: opener,
           output_retry_ms: 1_000,
           output_failure_ms: 10_000},
          id: name
        )

      assert_receive {:pressure_port, port}
      :ok = Manager.subscribe(name)
      payload = :binary.copy(<<0>>, 128 * 1_024)

      results =
        Enum.map(1..100, fn frame_seq ->
          Manager.send_render_commands(
            name,
            frame_commands(frame_seq, max(frame_seq - 1, 0), 1, payload)
          )
        end)

      assert :unwritable in results
      pressure = Manager.output_pressure(name)
      frame_bytes = IO.iodata_length(frame_commands(100, 99, 1, payload))
      assert pressure.current_bytes > 0
      assert pressure.replacement_bytes > 0
      assert pressure.retained_bytes <= frame_bytes * 2

      send_port_data(pid, port, <<0x02, 101::16, 51::16>>)
      assert_receive {:minga_input, {:resize, 101, 51}}, 1_000
      assert Manager.terminal_size(name) == {101, 51}

      {:message_queue_len, queue_len} = Process.info(pid, :message_queue_len)
      assert queue_len <= 1
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
    @describetag :heavy
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

      assert_receive {:minga_input, {:key_press, ?j, 0, 0}}
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
      assert :unwritable = Manager.send_commands(name, [Protocol.encode_commit_frame(0)])
    end

    test "send_commands returns accepted when connected" do
      name = unique_name()
      {_pid, _fake_port} = start_connected(name)

      assert :accepted = Manager.send_commands(name, [Protocol.encode_commit_frame(0)])
    end

    test "send_commands emits actual port write telemetry when connected" do
      name = unique_name()
      parent = self()
      handler_id = "manager-port-write-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:minga, :port, :write, :stop],
        fn _event, measurements, metadata, _config ->
          send(parent, {:port_write, measurements, metadata})
        end,
        nil
      )

      try do
        {_pid, _fake_port} = start_connected(name)
        command = Protocol.encode_commit_frame(0)

        assert :accepted = Manager.send_commands(name, [command])

        assert_receive {:port_write, %{duration: duration}, %{byte_count: byte_count}},
                       1_000

        assert duration >= 0
        assert byte_count == byte_size(command)
      after
        :telemetry.detach(handler_id)
      end
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

  defp start_connected(name, extra_opts \\ []) do
    opener = fake_port_opener()

    opts =
      [
        name: name,
        renderer_path: "/nonexistent",
        port_mode: :connected,
        port_opener: opener
      ] ++ extra_opts

    pid = start_supervised!({Manager, opts}, id: name)

    assert_receive {:fake_port, fake_port}
    {pid, fake_port}
  end

  defp frame_commands(frame_seq, base_frame_seq, generation, payload \\ <<>>) do
    [
      Protocol.encode_begin_frame(frame_seq, base_frame_seq, generation),
      <<0x70, payload::binary>>,
      Protocol.encode_commit_frame(frame_seq)
    ]
  end
end
