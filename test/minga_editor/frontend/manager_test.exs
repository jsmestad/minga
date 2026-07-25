defmodule MingaEditor.Frontend.ManagerTest do
  # Connected-mode tests use real OS ports, so this mixed module remains serialized.
  use ExUnit.Case, async: false

  alias MingaEditor.Frontend.Manager
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

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

      send_port_data(pid, nil, <<0x01, ?h::32, 0::8, 1::32>>)

      assert_receive {:minga_input, {:key_press, ?h, 0, 1}}
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

      send_port_data(pid, nil, ready_packet(80, 24))

      assert_receive {:minga_input, {:ready, 80, 24}}
      refute_receive {:minga_input, {:ready, 80, 24}}, 50
    end
  end

  describe "event handling" do
    test "versioned ready with the matching protocol_version becomes ready" do
      name = unique_name()
      pid = start_manager(name)
      :ok = Manager.subscribe(name)

      ready = ready_packet(120, 40)
      send_port_data(pid, nil, ready)

      assert Manager.ready?(name)
      assert Manager.terminal_size(name) == {120, 40}
      assert_receive {:minga_input, {:ready, 120, 40}}
    end

    test "ready with a mismatched protocol_version stays not ready (no silent desync)" do
      name = unique_name()
      parent = self()

      commander = fn _port, batch, [:nosuspend] ->
        send(parent, {:port_command, batch})
        true
      end

      {pid, fake_port} = start_connected(name, port_commander: commander)
      :ok = Manager.subscribe(name)

      bad = Minga.Protocol.Opcodes.protocol_version() + 99
      ready = ready_packet(120, 40, bad)
      send_port_data(pid, fake_port, ready)

      refute Manager.ready?(name)
      assert_receive {:port_command, <<0x18, _::binary>> = protocol_error}
      assert protocol_error =~ "this frontend speaks protocol v#{bad}"
      refute_receive {:minga_input, {:ready, 120, 40}}, 50
    end

    test "short unversioned ready is rejected without marking the frontend ready" do
      name = unique_name()
      pid = start_manager(name)
      :ok = Manager.subscribe(name)

      send_port_data(pid, nil, <<0x03, 120::16, 40::16>>)

      refute Manager.ready?(name)
      assert Manager.terminal_size(name) == nil
      refute_receive {:minga_input, {:ready, 120, 40}}, 50
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

      send_port_data(pid, nil, ready_packet(80, 24))
      assert Manager.ready?(name)

      send(pid, {nil, {:exit_status, 1}})

      refute Manager.ready?(name)
    end
  end

  describe "ready event replay on late subscribe" do
    test "late subscriber receives replayed ready event" do
      name = unique_name()
      pid = start_manager(name)

      send_port_data(pid, nil, ready_packet(80, 24))
      assert Manager.ready?(name)

      :ok = Manager.subscribe(name)

      assert_receive {:minga_input, {:ready, 80, 24}}
    end

    test "replayed ready uses current terminal size" do
      name = unique_name()
      pid = start_manager(name)

      send_port_data(pid, nil, ready_packet(80, 24))
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

      send_port_data(pid, fake_port, ready_packet(80, 24))
      assert Manager.ready?(name)

      :ok = Manager.subscribe(name)

      assert_receive {:minga_input, {:ready, 80, 24}}
    end

    @tag :heavy
    test "no replay after port EOF clears ready state" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)

      send_port_data(pid, fake_port, ready_packet(80, 24))
      assert Manager.ready?(name)
      send(pid, {fake_port, :eof})
      refute Manager.ready?(name)

      :ok = Manager.subscribe(name)

      refute_receive {:minga_input, {:ready, _, _}}, 50
    end
  end

  describe "output pressure" do
    test "the output failure budget clears retained controls and stops retries per generation" do
      name = unique_name()
      transport = start_supervised!({Agent, fn -> %{attempts: 0, writable: false} end})

      commander = fn _port, _batch, [:nosuspend] ->
        Agent.get_and_update(transport, fn state ->
          {state.writable, %{state | attempts: state.attempts + 1}}
        end)
      end

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 1,
          output_failure_ms: 5
        )

      :ok = Manager.subscribe(name)
      title = Protocol.encode_set_title("Retained title")

      assert :unwritable = Manager.send_render_commands(name, frame_commands(11, 0, 1))
      assert :unwritable = Manager.send_commands(name, [title])
      assert_receive {:minga_input, {:request_keyframe, 0, 1}}, 1_000

      pressure = Manager.output_pressure(name)
      assert pressure.current_bytes == 0
      assert pressure.replacement_bytes == 0
      assert pressure.control_batches == 0
      assert pressure.total_retained_bytes == 0

      attempts_after_recovery = Agent.get(transport, & &1.attempts)
      refute_receive {:minga_input, {:request_keyframe, 0, 1}}, 30
      assert Agent.get(transport, & &1.attempts) == attempts_after_recovery

      assert :unwritable = Manager.send_render_commands(name, frame_commands(12, 0, 2))
      assert_receive {:minga_input, {:request_keyframe, 0, 2}}, 1_000

      Agent.update(transport, &%{&1 | writable: true})
      assert :accepted = Manager.send_render_commands(name, frame_commands(13, 0, 3))

      send_port_data(pid, fake_port, <<0x0A, 1::32, 11::32>>)
      send_port_data(pid, fake_port, <<0x0A, 2::32, 12::32>>)
      refute_receive {:minga_input, {:frame_applied, _, _}}, 30

      send_port_data(pid, fake_port, <<0x0A, 3::32, 13::32>>)
      assert_receive {:minga_input, {:frame_applied, 3, 13}}

      pressure = Manager.output_pressure(name)
      assert pressure.minimum_ack_generation == 3
      assert pressure.last_admitted_generation == 3
      assert pressure.last_admitted_frame_seq == 13
      assert pressure.last_applied_generation == 3
      assert pressure.last_applied_frame_seq == 13
    end

    test "future acknowledgements do not poison correlation for later admitted frames" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)
      :ok = Manager.subscribe(name)

      assert :accepted = Manager.send_render_commands(name, frame_commands(10, 0, 1))
      send_port_data(pid, fake_port, <<0x0A, 1::32, 10::32>>)
      assert_receive {:minga_input, {:frame_applied, 1, 10}}

      send_port_data(pid, fake_port, <<0x0A, 1::32, 11::32>>)
      send_port_data(pid, fake_port, <<0x0A, 0xFFFFFFFF::32, 1::32>>)
      refute_receive {:minga_input, {:frame_applied, _, _}}, 30

      pressure = Manager.output_pressure(name)
      assert pressure.last_admitted_generation == 1
      assert pressure.last_admitted_frame_seq == 10
      assert pressure.last_applied_generation == 1
      assert pressure.last_applied_frame_seq == 10

      assert :accepted = Manager.send_render_commands(name, frame_commands(11, 10, 1))
      send_port_data(pid, fake_port, <<0x0A, 1::32, 11::32>>)
      assert_receive {:minga_input, {:frame_applied, 1, 11}}
    end

    test "an unwritable font configuration is retained and retried before later frames" do
      name = unique_name()
      parent = self()
      writable = start_supervised!({Agent, fn -> false end}, id: make_ref())

      commander = fn _port, batch, [:nosuspend] ->
        admitted? = Agent.get(writable, & &1)
        send(parent, {:output_attempt, admitted?, batch})
        admitted?
      end

      {_pid, _fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 20,
          output_failure_ms: 1_000
        )

      font_command = Protocol.encode_set_font("Fira Code", 15, true, :regular)
      frame_commands = frame_commands(10, 0, 1)
      frame_batch = IO.iodata_to_binary(frame_commands)

      assert :unwritable = Manager.send_commands(name, [font_command])
      assert_receive {:output_attempt, false, ^font_command}
      assert :unwritable = Manager.send_render_commands(name, frame_commands)

      pressure = Manager.output_pressure(name)
      assert pressure.control_batches == 1
      assert pressure.control_bytes == byte_size(font_command)
      assert pressure.current_bytes == byte_size(frame_batch)

      Agent.update(writable, fn _ -> true end)
      assert_receive {:output_attempt, true, first_admitted}, 1_000
      assert_receive {:output_attempt, true, second_admitted}, 1_000
      assert first_admitted == font_command
      assert second_admitted == frame_batch

      pressure = Manager.output_pressure(name)
      assert pressure.control_batches == 0
      assert pressure.control_bytes == 0
      assert pressure.current_bytes == 0
    end

    test "clipboard writes for distinct pasteboards are both retained and admitted" do
      name = unique_name()
      parent = self()
      writable = start_supervised!({Agent, fn -> false end}, id: make_ref())

      commander = fn _port, batch, [:nosuspend] ->
        admitted? = Agent.get(writable, & &1)
        send(parent, {:clipboard_attempt, admitted?, batch})
        admitted?
      end

      {_pid, _fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 20,
          output_failure_ms: 1_000
        )

      general = ProtocolGUI.encode_clipboard_write("general", :general)
      find = ProtocolGUI.encode_clipboard_write("find", :find)

      assert :unwritable = Manager.send_commands(name, [general])
      assert_receive {:clipboard_attempt, false, ^general}
      assert :unwritable = Manager.send_commands(name, [find])
      assert Manager.output_pressure(name).control_batches == 2

      Agent.update(writable, fn _ -> true end)
      assert_receive {:clipboard_attempt, true, ^general}, 1_000
      assert_receive {:clipboard_attempt, true, ^find}, 1_000
      assert Manager.output_pressure(name).control_batches == 0
    end

    test "clipboard writes coalesce only within the same pasteboard" do
      name = unique_name()
      parent = self()
      writable = start_supervised!({Agent, fn -> false end}, id: make_ref())

      commander = fn _port, batch, [:nosuspend] ->
        admitted? = Agent.get(writable, & &1)
        send(parent, {:clipboard_attempt, admitted?, batch})
        admitted?
      end

      {_pid, _fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 20,
          output_failure_ms: 1_000
        )

      old_general = ProtocolGUI.encode_clipboard_write("old", :general)
      latest_general = ProtocolGUI.encode_clipboard_write("latest", :general)
      find = ProtocolGUI.encode_clipboard_write("find", :find)

      assert :unwritable = Manager.send_commands(name, [old_general])
      assert_receive {:clipboard_attempt, false, ^old_general}
      assert :unwritable = Manager.send_commands(name, [find])
      assert :unwritable = Manager.send_commands(name, [latest_general])
      assert Manager.output_pressure(name).control_batches == 2

      Agent.update(writable, fn _ -> true end)
      assert_receive {:clipboard_attempt, true, ^latest_general}, 1_000
      assert_receive {:clipboard_attempt, true, ^find}, 1_000
      refute_receive {:clipboard_attempt, true, ^old_general}, 30
      assert Manager.output_pressure(name).control_batches == 0
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

      send_port_data(pid, fake_port, ready_packet(80, 24))

      assert Manager.ready?(name)
      assert Manager.terminal_size(name) == {80, 24}
      assert_receive {:minga_input, {:ready, 80, 24}}

      send_port_data(pid, fake_port, <<0x01, ?j::32, 0::8, 1::32>>)

      assert_receive {:minga_input, {:key_press, ?j, 0, 1}}
    end

    test "EOF on connected port clears ready state" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)
      :ok = Manager.subscribe(name)

      send_port_data(pid, fake_port, ready_packet(80, 24))
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

  defp ready_packet(width, height, version \\ Minga.Protocol.Opcodes.protocol_version()) do
    capabilities = <<0, 2, 1, 0, 0, 0, 1, 1, 64 * 1024 * 1024::32, 0::32, 0::32>>
    <<0x03, width::16, height::16, 2, 20, capabilities::binary, version::16>>
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
