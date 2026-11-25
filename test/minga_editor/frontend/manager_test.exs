defmodule MingaEditor.Frontend.ManagerTest do
  # Connected-mode tests use real OS ports, so this mixed module remains serialized.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.Config.Options
  alias Minga.Events
  alias Minga.Events.LogMessageEvent
  alias MingaEditor.Frontend.Manager
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Frontend.TerminalOverrides

  defp unique_name, do: :"port_mgr_#{:erlang.unique_integer([:positive])}"

  describe "startup" do
    test "starts disconnected when renderer binary is missing" do
      name = unique_name()
      start_manager(name)

      refute Manager.ready?(name)
      assert Manager.terminal_size(name) == nil
    end

    @tag :heavy
    @tag capture_log: true
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
         tty_path: "/dev/tty",
         renderer_env: fn -> [] end,
         renderer_exit_timeout_ms: 0},
        id: name
      )

      assert_receive {:port_open_args, {:spawn_executable, ^renderer_path}, opts}
      assert :binary in opts
      assert :use_stdio in opts
      assert {:packet, 4} in opts
      assert {:env, [{~c"MINGA_TTY", ~c"/dev/tty"}]} in opts
    end

    test "the renderer is started with the terminal features the user forces" do
      name = unique_name()

      renderer_path =
        Path.join(System.tmp_dir!(), "minga-renderer-go-#{System.unique_integer([:positive])}")

      File.write!(renderer_path, "")
      parent = self()
      on_exit(fn -> File.rm(renderer_path) end)

      capturing_opener = fn _spec, opts ->
        send(parent, {:port_env, Keyword.fetch!(opts, :env)})
        Port.open({:spawn, "cat 2>/dev/null"}, [:binary, {:packet, 4}])
      end

      start_supervised!(
        {Manager,
         name: name,
         renderer_path: renderer_path,
         port_opener: capturing_opener,
         tty_path: "/dev/tty",
         renderer_env: fn ->
           TerminalOverrides.env(%{underline_color: :off, styled_underlines: :on})
         end,
         renderer_exit_timeout_ms: 0},
        id: name
      )

      assert_receive {:port_env, env}

      assert env == [
               {~c"MINGA_TTY", ~c"/dev/tty"},
               {~c"MINGA_TERMINAL_FEATURES", ~c"styled_underlines=on,underline_color=off"}
             ]
    end
  end

  test "native log packets reach Messages with GUI attribution and original severity" do
    previous_port_level = Options.get(:log_level_port)
    previous_logger_level = Logger.level()
    Options.set(:log_level_port, :debug)
    Logger.configure(level: :warning)
    Events.subscribe(:log_message)

    on_exit(fn ->
      Options.set(:log_level_port, previous_port_level)
      Logger.configure(level: previous_logger_level)
    end)

    {pid, port} = start_connected(unique_name())
    <<header::binary-size(7), 0, rest::binary>> = ready_packet(80, 24)
    send_port_data(pid, port, <<header::binary, 1, rest::binary>>)
    tag = "gui-log-#{System.unique_integer([:positive])}"

    for {level, wire_level} <- Enum.with_index([:error, :warning, :info, :debug]) do
      text = "#{tag}-#{level}"
      expected = "[GUI/#{level}] #{text}"
      send_port_data(pid, port, <<0x60, wire_level, byte_size(text)::16, text::binary>>)

      assert_receive {:minga_event, :log_message,
                      %LogMessageEvent{text: ^expected, level: ^level}}

      assert MingaEditor.UI.Panel.MessageStore.parse_prefix(expected) == {level, :gui, text}
    end

    Options.set(:log_level_port, :warning)
    ignored = "#{tag}-filtered"
    send_port_data(pid, port, <<0x60, 3, byte_size(ignored)::16, ignored::binary>>)
    assert Manager.ready?(pid)
    filtered_entry = "[GUI/debug] #{ignored}"
    refute_received {:minga_event, :log_message, %LogMessageEvent{text: ^filtered_entry}}
  end

  describe "send_commands/2" do
    test "returns unwritable when no port is open" do
      name = unique_name()
      start_manager(name)

      assert :unwritable = Manager.send_commands(name, [])
      assert :unwritable = Manager.send_commands(name, [Protocol.encode_commit_frame(0)])
    end

    test "a frame with no port is refused without retention" do
      name = unique_name()
      start_manager(name)

      assert {:refused, :not_ready} = Manager.send_render_commands(name, frame_commands(1, 0, 1))
      assert {:refused, :not_ready} = Manager.send_commands(name, frame_commands(2, 0, 1))
      assert Manager.output_pressure(name).total_retained_bytes == 0
    end

    test "a frame after the transport disconnects is refused without a write" do
      name = unique_name()
      parent = self()

      commander = fn _port, batch, [:nosuspend] ->
        send(parent, {:port_command, batch})
        true
      end

      {pid, fake_port} = start_connected(name, port_commander: commander)
      mark_ready(name, pid, fake_port)
      send(pid, {fake_port, :eof})
      refute Manager.ready?(name)

      assert {:refused, :not_ready} = Manager.send_render_commands(name, frame_commands(1, 0, 1))
      refute_received {:port_command, _batch}
      assert Manager.output_pressure(name).total_retained_bytes == 0
    end

    test "a frame before ready is refused without a write or retention" do
      name = unique_name()
      parent = self()

      commander = fn _port, batch, [:nosuspend] ->
        send(parent, {:port_command, batch})
        true
      end

      {_pid, _fake_port} = start_connected(name, port_commander: commander)
      refute Manager.ready?(name)

      assert {:refused, :not_ready} =
               Manager.send_render_commands(name, frame_commands(1, 0, 1))

      refute_received {:port_command, _batch}
      pressure = Manager.output_pressure(name)
      assert pressure.current_frame_seq == nil
      assert pressure.total_retained_bytes == 0
    end

    test "a frame under output pressure after ready stays unwritable and is retained" do
      name = unique_name()

      {pid, fake_port} =
        start_connected(name,
          port_commander: fn _port, _batch, [:nosuspend] -> false end,
          output_retry_ms: 60_000,
          output_failure_ms: 60_000
        )

      mark_ready(name, pid, fake_port)

      assert :unwritable = Manager.send_render_commands(name, frame_commands(1, 0, 1))
      assert Manager.output_pressure(name).current_frame_seq == 1
    end
  end

  describe "send_lifecycle_command/2" do
    test "temporary backpressure rejects without retaining and permits correlated retry" do
      name = unique_name()
      parent = self()
      writable = start_supervised!({Agent, fn -> false end}, id: make_ref())

      commander = fn _port, batch, [:nosuspend] ->
        admitted? = Agent.get(writable, & &1)
        send(parent, {:lifecycle_attempt, admitted?, batch})
        admitted?
      end

      {_pid, _fake_port} = start_connected(name, port_commander: commander)
      response = Protocol.encode_application_quit_response(41, :needs_decision, 2, "", "")

      assert :unwritable = Manager.send_lifecycle_command(name, response)
      assert_receive {:lifecycle_attempt, false, ^response}
      assert Manager.output_pressure(name).control_batches == 0
      assert Manager.output_pressure(name).total_retained_bytes == 0

      Agent.update(writable, fn _ -> true end)
      assert :accepted = Manager.send_lifecycle_command(name, response)
      assert_receive {:lifecycle_attempt, true, ^response}
    end

    test "disconnected transport rejects without retaining lifecycle output" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)
      response = Protocol.encode_application_quit_response(42, :proceeding, 0, "", "")

      send(pid, {fake_port, :eof})
      _ = :sys.get_state(pid)

      assert :disconnected = Manager.send_lifecycle_command(name, response)
      assert Manager.output_pressure(name).control_batches == 0
      assert Manager.output_pressure(name).total_retained_bytes == 0
    end
  end

  test "alert withdrawals, including owner death, survive pressure without retaining required controls" do
    name = unique_name()
    parent = self()
    writable = start_supervised!({Agent, fn -> true end}, id: make_ref())
    second_owner = start_supervised!({Agent, fn -> nil end}, id: make_ref(), restart: :temporary)

    commander = fn _port, batch, [:nosuspend] ->
      admitted? = Agent.get(writable, & &1)
      send(parent, {:desktop_output, admitted?, batch})
      admitted?
    end

    {pid, fake_port} = start_connected(name, port_commander: commander, output_failure_ms: 0)

    desktop = fn kind, id, owner ->
      send(pid, {
        :minga_event,
        :agent_desktop_notification,
        %{kind: kind, id: id, owner: owner}
      })

      Protocol.encode_agent_desktop_notification(kind, id)
    end

    before_ready = desktop.(:needs_you, <<0::128>>, self())
    mark_ready(name, pid, fake_port)
    refute_received {:desktop_output, _, ^before_ready}

    for {id, owner} <- [{<<1::128>>, self()}, {<<2::128>>, second_owner}] do
      posted = desktop.(:needs_you, id, owner)
      assert_receive {:desktop_output, true, ^posted}
    end

    Agent.update(writable, fn _ -> false end)
    first_clear = desktop.(:withdrawn, <<1::128>>, self())
    second_clear = Protocol.encode_agent_desktop_notification(:withdrawn, <<2::128>>)
    Process.exit(second_owner, :kill)
    assert_receive {:desktop_output, false, ^second_clear}
    dropped_post = desktop.(:needs_you, <<3::128>>, self())
    assert_receive {:desktop_output, false, ^dropped_post}
    dropped_clear = desktop.(:withdrawn, <<3::128>>, self())
    assert Manager.output_pressure(name).control_batches == 0
    assert Manager.ready?(name)

    Agent.update(writable, fn _ -> true end)
    assert_receive {:desktop_output, true, ^first_clear}, 1_000
    assert_receive {:desktop_output, true, ^second_clear}, 1_000
    refute_received {:desktop_output, true, ^dropped_post}
    refute_received {:desktop_output, _, ^dropped_clear}
  end

  test "a new alert identity for a session that already has one withdraws the old alert and posts the new one" do
    name = unique_name()
    parent = self()

    commander = fn _port, batch, [:nosuspend] ->
      send(parent, {:desktop_output, batch})
      true
    end

    {pid, fake_port} = start_connected(name, port_commander: commander)
    mark_ready(name, pid, fake_port)

    desktop = fn kind, id ->
      send(pid, {:minga_event, :agent_desktop_notification, %{kind: kind, id: id, owner: parent}})
      Protocol.encode_agent_desktop_notification(kind, id)
    end

    first = desktop.(:needs_you, <<1::128>>)
    assert_receive {:desktop_output, ^first}

    # The same identity again posts nothing more.
    _ = desktop.(:needs_you, <<1::128>>)
    # The editor restarted or reattached the session and lost the first identity.
    second = desktop.(:needs_you, <<2::128>>)
    withdrawn = Protocol.encode_agent_desktop_notification(:withdrawn, <<1::128>>)
    assert_receive {:desktop_output, ^withdrawn}
    assert_receive {:desktop_output, ^second}
    refute_received {:desktop_output, ^first}

    # Withdrawing the new identity removes it.
    second_withdrawn = desktop.(:withdrawn, <<2::128>>)
    assert_receive {:desktop_output, ^second_withdrawn}
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

    test "what a frontend said about itself reaches a subscriber that registers late, after its ready" do
      name = unique_name()
      pid = start_manager(name)

      # The frontend is ready, says it is in the background and reports its terminal before anyone listens.
      send_port_data(pid, nil, ready_packet(80, 24))
      send_port_data(pid, nil, <<0x13, 0>>)
      # true_color (1) detected (2)
      send_port_data(pid, nil, <<0x62, 4::16, 1, 1, 2, 1>>)
      assert Manager.ready?(name)

      :ok = Manager.subscribe(name)

      # They arrive in the frontend's order: ready first, because ready resets what the editor knew.
      assert_receive {:minga_input, first}
      assert_receive {:minga_input, second}
      assert_receive {:minga_input, third}

      assert first == {:ready, 80, 24}
      assert second == {:frontend_foreground, :background}
      assert {:terminal_report, report} = third
      assert report.features == %{true_color: {:detected, :answered}}
    end

    test "a new ready forgets what the last connection said about itself" do
      name = unique_name()
      pid = start_manager(name)

      send_port_data(pid, nil, ready_packet(80, 24))
      send_port_data(pid, nil, <<0x13, 0>>)
      send_port_data(pid, nil, <<0x62, 4::16, 1, 1, 2, 1>>)
      send_port_data(pid, nil, ready_packet(100, 30))
      assert Manager.terminal_size(name) == {100, 30}

      :ok = Manager.subscribe(name)

      assert_receive {:minga_input, {:ready, 100, 30}}
      refute_receive {:minga_input, {:frontend_foreground, _status}}, 50
      refute_receive {:minga_input, {:terminal_report, _report}}, 50
    end

    test "a frontend that said nothing about itself replays only its ready" do
      name = unique_name()
      pid = start_manager(name)
      send_port_data(pid, nil, ready_packet(80, 24))
      assert Manager.ready?(name)

      :ok = Manager.subscribe(name)

      assert_receive {:minga_input, {:ready, 80, 24}}
      refute_receive {:minga_input, {:frontend_foreground, _status}}, 50
      refute_receive {:minga_input, {:terminal_report, _report}}, 50
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

    test "an admitted mismatch control revokes frames and invalidates their retry" do
      name = unique_name()
      parent = self()
      outcomes = start_supervised!({Agent, fn -> [false, true] end}, id: make_ref())

      commander = fn _port, batch, [:nosuspend] ->
        admitted? =
          Agent.get_and_update(outcomes, fn
            [outcome | rest] -> {outcome, rest}
            [] -> {true, []}
          end)

        send(parent, {:port_command, admitted?, batch})
        admitted?
      end

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 60_000,
          output_failure_ms: 60_000
        )

      :ok = Manager.subscribe(name)
      mark_ready(name, pid, fake_port)
      assert_receive {:minga_input, {:ready, 80, 24}}

      old_frame_commands = frame_commands(1, 0, 1)
      old_frame_batch = IO.iodata_to_binary(old_frame_commands)
      assert :unwritable = Manager.send_render_commands(name, old_frame_commands)
      assert_receive {:port_command, false, ^old_frame_batch}
      old_retry_token = :sys.get_state(pid).output_pressure.retry_token

      bad = Minga.Protocol.Opcodes.protocol_version() + 99
      ready = ready_packet(120, 40, bad)
      send_port_data(pid, fake_port, ready)

      refute Manager.ready?(name)
      assert_receive {:port_command, true, <<0x18, _::binary>> = protocol_error}
      assert protocol_error =~ "this frontend speaks protocol v#{bad}"
      refute_receive {:minga_input, {:ready, 120, 40}}, 50

      pressure = :sys.get_state(pid).output_pressure
      assert pressure.current == nil
      assert pressure.replacement == nil
      assert pressure.retry_token == nil
      assert pressure.unwritable_since == nil

      later_frame_commands = frame_commands(2, 1, 1)
      later_frame_batch = IO.iodata_to_binary(later_frame_commands)

      assert {:refused, :not_ready} =
               Manager.send_render_commands(name, later_frame_commands)

      send(pid, {:retry_frontend_output, old_retry_token})
      _state = :sys.get_state(pid)

      refute_received {:port_command, _admitted, ^old_frame_batch}
      refute_received {:port_command, _admitted, ^later_frame_batch}
      refute_received {:port_command, _admitted, _other_batch}
      refute_received {:minga_input, {:request_keyframe, _, _}}
    end

    test "a mismatch revokes an already retained frame before retrying its control" do
      name = unique_name()
      parent = self()
      writable = start_supervised!({Agent, fn -> false end}, id: make_ref())

      commander = fn _port, batch, [:nosuspend] ->
        admitted? = Agent.get(writable, & &1)
        send(parent, {:mismatch_output_attempt, admitted?, batch})
        admitted?
      end

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 60_000,
          output_failure_ms: 60_000
        )

      :ok = Manager.subscribe(name)
      mark_ready(name, pid, fake_port)
      assert_receive {:minga_input, {:ready, 80, 24}}

      old_frame_commands = frame_commands(1, 0, 1)
      old_frame_batch = IO.iodata_to_binary(old_frame_commands)
      assert :unwritable = Manager.send_render_commands(name, old_frame_commands)
      assert_receive {:mismatch_output_attempt, false, ^old_frame_batch}

      old_pressure = :sys.get_state(pid).output_pressure
      old_retry_token = old_pressure.retry_token
      old_unwritable_since = old_pressure.unwritable_since

      bad = Minga.Protocol.Opcodes.protocol_version() + 99
      send_port_data(pid, fake_port, ready_packet(120, 40, bad))
      refute Manager.ready?(name)

      assert_receive {:mismatch_output_attempt, false, <<0x18, _::binary>> = protocol_error}
      mismatch_pressure = :sys.get_state(pid).output_pressure
      assert mismatch_pressure.current == nil
      assert mismatch_pressure.replacement == nil
      assert mismatch_pressure.retry_token == old_retry_token
      assert mismatch_pressure.unwritable_since == old_unwritable_since

      later_frame_commands = frame_commands(2, 1, 1)
      later_frame_batch = IO.iodata_to_binary(later_frame_commands)

      assert {:refused, :not_ready} =
               Manager.send_render_commands(name, later_frame_commands)

      refute_received {:mismatch_output_attempt, _admitted, ^later_frame_batch}
      refute_received {:mismatch_output_attempt, _admitted, _other_batch}

      Agent.update(writable, fn _ -> true end)
      send(pid, {:retry_frontend_output, old_retry_token})
      _state = :sys.get_state(pid)

      assert_received {:mismatch_output_attempt, true, ^protocol_error}
      refute_received {:mismatch_output_attempt, _admitted, ^old_frame_batch}
      refute_received {:mismatch_output_attempt, _admitted, ^later_frame_batch}
      refute_received {:minga_input, {:request_keyframe, _, _}}
      assert Manager.output_pressure(name).total_retained_bytes == 0
      refute Manager.ready?(name)
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
    test "a control-only timeout reports once, invalidates its timer, and stops attempts" do
      name = unique_name()
      attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      commander = fn _port, _batch, [:nosuspend] ->
        Agent.update(attempts, &(&1 + 1))
        false
      end

      {pid, _fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 60_000,
          output_failure_ms: 0
        )

      :ok = Manager.subscribe(name)
      clipboard = ProtocolGUI.encode_clipboard_write("retained clipboard", :general)

      assert :unwritable = Manager.send_commands(name, [clipboard])
      retry_token = :sys.get_state(pid).output_pressure.retry_token

      log =
        capture_log(fn ->
          send(pid, {:retry_frontend_output, retry_token})
          _state = :sys.get_state(pid)
          send(pid, {:retry_frontend_output, retry_token})
          _state = :sys.get_state(pid)
        end)

      assert log =~ "Frontend output transport remained unwritable with retained control messages"

      assert [["Frontend output transport remained unwritable"]] =
               Regex.scan(~r/Frontend output transport remained unwritable/, log)

      refute_received {:minga_input, {:request_keyframe, _, _}}
      refute_received {:minga_input, {:frame_applied, _, _}}
      assert Agent.get(attempts, & &1) == 1

      pressure = Manager.output_pressure(name)
      assert pressure.current_bytes == 0
      assert pressure.replacement_bytes == 0
      assert pressure.control_batches == 0
      assert pressure.total_retained_bytes == 0
      assert :unwritable = Manager.send_commands(name, [clipboard])
      assert Agent.get(attempts, & &1) == 1
    end

    test "a frame-plus-control timeout fails the transport without requesting a keyframe" do
      name = unique_name()
      attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      commander = fn _port, _batch, [:nosuspend] ->
        Agent.update(attempts, &(&1 + 1))
        false
      end

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 60_000,
          output_failure_ms: 0
        )

      :ok = Manager.subscribe(name)
      mark_ready(name, pid, fake_port)
      assert :unwritable = Manager.send_render_commands(name, frame_commands(11, 0, 1))
      assert :unwritable = Manager.send_commands(name, [Protocol.encode_set_title("title")])
      retry_token = :sys.get_state(pid).output_pressure.retry_token

      send(pid, {:retry_frontend_output, retry_token})
      _state = :sys.get_state(pid)

      refute_received {:minga_input, {:request_keyframe, _, _}}
      assert Manager.output_pressure(name).total_retained_bytes == 0
      assert Agent.get(attempts, & &1) == 1
    end

    test "a frame-only timeout keeps correlated keyframe recovery" do
      name = unique_name()
      attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      commander = fn _port, _batch, [:nosuspend] ->
        Agent.update(attempts, &(&1 + 1))
        false
      end

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 60_000,
          output_failure_ms: 0
        )

      :ok = Manager.subscribe(name)
      mark_ready(name, pid, fake_port)
      assert :unwritable = Manager.send_render_commands(name, frame_commands(11, 0, 1))
      retry_token = :sys.get_state(pid).output_pressure.retry_token

      send(pid, {:retry_frontend_output, retry_token})
      _state = :sys.get_state(pid)

      assert_received {:minga_input, {:request_keyframe, 0, 1}}
      assert Agent.get(attempts, & &1) == 1

      send(pid, {:retry_frontend_output, retry_token})
      _state = :sys.get_state(pid)

      refute_received {:minga_input, {:request_keyframe, _, _}}
      assert Agent.get(attempts, & &1) == 1

      pressure = Manager.output_pressure(name)
      assert pressure.minimum_ack_generation == 2
      assert pressure.total_retained_bytes == 0
    end

    test "temporary control pressure drains before the failure budget" do
      name = unique_name()

      transport =
        start_supervised!({Agent, fn -> %{attempts: 0, writable: false} end}, id: make_ref())

      commander = fn _port, _batch, [:nosuspend] ->
        Agent.get_and_update(transport, fn state ->
          {state.writable, %{state | attempts: state.attempts + 1}}
        end)
      end

      {pid, _fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 60_000,
          output_failure_ms: 1_000
        )

      assert :unwritable = Manager.send_commands(name, [Protocol.encode_set_title("title")])
      retry_token = :sys.get_state(pid).output_pressure.retry_token
      Agent.update(transport, &%{&1 | writable: true})

      send(pid, {:retry_frontend_output, retry_token})
      state = :sys.get_state(pid)

      assert state.port != nil
      assert Manager.output_pressure(name).total_retained_bytes == 0
      assert Agent.get(transport, & &1.attempts) == 2
    end

    test "a protocol-mismatch response timeout stays not-ready and terminates transport" do
      name = unique_name()
      attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      commander = fn _port, _batch, [:nosuspend] ->
        Agent.update(attempts, &(&1 + 1))
        false
      end

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 60_000,
          output_failure_ms: 0
        )

      :ok = Manager.subscribe(name)
      bad_version = Minga.Protocol.Opcodes.protocol_version() + 1
      send_port_data(pid, fake_port, ready_packet(80, 24, bad_version))
      refute Manager.ready?(name)
      retry_token = :sys.get_state(pid).output_pressure.retry_token

      send(pid, {:retry_frontend_output, retry_token})
      _state = :sys.get_state(pid)

      refute Manager.ready?(name)
      refute_received {:minga_input, {:ready, _, _}}
      refute_received {:minga_input, {:request_keyframe, _, _}}
      assert Manager.output_pressure(name).total_retained_bytes == 0
      assert Agent.get(attempts, & &1) == 1
    end

    test "a concurrent port exit after terminal failure is ignored" do
      name = unique_name()
      attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      commander = fn _port, _batch, [:nosuspend] ->
        Agent.update(attempts, &(&1 + 1))
        false
      end

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 60_000,
          output_failure_ms: 0
        )

      assert :unwritable = Manager.send_commands(name, [Protocol.encode_set_title("title")])
      retry_token = :sys.get_state(pid).output_pressure.retry_token

      log =
        capture_log(fn ->
          send(pid, {:retry_frontend_output, retry_token})
          send(pid, {fake_port, {:exit_status, 1}})
          _state = :sys.get_state(pid)
        end)

      assert [["Frontend output transport remained unwritable"]] =
               Regex.scan(~r/Frontend output transport remained unwritable/, log)

      refute log =~ "Renderer: crashed"
      assert Agent.get(attempts, & &1) == 1
    end

    test "a port exit before the timeout invalidates the pending retry" do
      name = unique_name()
      attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      commander = fn _port, _batch, [:nosuspend] ->
        Agent.update(attempts, &(&1 + 1))
        false
      end

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 60_000,
          output_failure_ms: 0
        )

      assert :unwritable = Manager.send_commands(name, [Protocol.encode_set_title("title")])
      retry_token = :sys.get_state(pid).output_pressure.retry_token

      log =
        capture_log(fn ->
          send(pid, {fake_port, {:exit_status, 1}})
          send(pid, {:retry_frontend_output, retry_token})
          _state = :sys.get_state(pid)
        end)

      assert [["Renderer: crashed"]] = Regex.scan(~r/Renderer: crashed/, log)
      refute log =~ "Frontend output transport remained unwritable"
      assert Agent.get(attempts, & &1) == 1
      assert Manager.output_pressure(name).total_retained_bytes == 0
    end

    test "future acknowledgements do not poison correlation for later admitted frames" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)
      :ok = Manager.subscribe(name)
      mark_ready(name, pid, fake_port)

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

    test "recovery context reservations stay above applied connection watermarks" do
      name = unique_name()
      {pid, fake_port} = start_connected(name)
      :ok = Manager.subscribe(name)
      mark_ready(name, pid, fake_port)

      assert Manager.reserve_recovery_context(name) == {1, 1}
      assert Manager.reserve_recovery_context(name) == {2, 1}
      assert :accepted = Manager.send_render_commands(name, frame_commands(50, 0, 5))
      send_port_data(pid, fake_port, <<0x0A, 5::32, 50::32>>)
      assert_receive {:minga_input, {:frame_applied, 5, 50}}

      assert Manager.reserve_recovery_context(name) == {6, 51}
      send_port_data(pid, fake_port, <<0x0A, 5::32, 50::32>>)
      refute_receive {:minga_input, {:frame_applied, 5, 50}}, 30

      pressure = Manager.output_pressure(name)
      assert pressure.minimum_ack_generation == 6
      assert pressure.last_admitted_generation == 5
      assert pressure.last_applied_generation == 5
    end

    test "reservation fences writes in both mailbox orderings and revokes unwritable old frames" do
      name = unique_name()
      parent = self()
      writable = start_supervised!({Agent, fn -> true end}, id: make_ref())

      commander = fn _port, batch, [:nosuspend] ->
        admitted? = Agent.get(writable, & &1)
        send(parent, {:context_write, admitted?, batch})
        admitted?
      end

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 60_000,
          output_failure_ms: 60_000
        )

      :ok = Manager.subscribe(name)
      mark_ready(name, pid, fake_port)
      assert Manager.reserve_recovery_context(name) == {1, 1}
      old_commands = frame_commands(80, 0, 1)
      old_batch = IO.iodata_to_binary(old_commands)
      assert :accepted = Manager.send_render_commands(name, old_commands)
      assert_receive {:context_write, true, ^old_batch}

      Agent.update(writable, fn _ -> false end)
      retained_commands = frame_commands(81, 80, 1)
      retained_batch = IO.iodata_to_binary(retained_commands)
      assert :unwritable = Manager.send_render_commands(name, retained_commands)
      assert_receive {:context_write, false, ^retained_batch}
      assert :unwritable = Manager.send_render_commands(name, frame_commands(82, 81, 1))
      retry_token = :sys.get_state(pid).output_pressure.retry_token

      # The admitted frame has not acknowledged: its sequence still fences the
      # replacement. Retained frames never crossed the wire and are revoked.
      assert Manager.reserve_recovery_context(name) == {2, 81}
      reserved = :sys.get_state(pid).output_pressure
      assert reserved.current == nil
      assert reserved.replacement == nil
      assert reserved.last_admitted_frame_seq == 80
      assert reserved.last_applied_frame_seq == 0

      # An old-generation write ordered after reservation must not touch either
      # the commander or the pressure/retention/admission watermarks.
      assert :unwritable = Manager.send_render_commands(name, frame_commands(999, 0, 1))
      send_port_data(pid, fake_port, <<0x0A, 1::32, 80::32>>)
      assert :sys.get_state(pid).output_pressure == reserved
      refute_receive {:context_write, _, _}, 30
      refute_receive {:minga_input, {:frame_applied, 1, 80}}, 30

      Agent.update(writable, fn _ -> true end)
      send(pid, {:retry_frontend_output, retry_token})
      _state = :sys.get_state(pid)
      refute_receive {:context_write, _, _}, 30

      replacement_commands = frame_commands(81, 0, 2)
      replacement_batch = IO.iodata_to_binary(replacement_commands)
      assert :accepted = Manager.send_render_commands(name, replacement_commands)
      assert_receive {:context_write, true, ^replacement_batch}
      send_port_data(pid, fake_port, <<0x0A, 2::32, 81::32>>)
      assert_receive {:minga_input, {:frame_applied, 2, 81}}
      assert Manager.reserve_recovery_context(name) == {3, 82}
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

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 20,
          output_failure_ms: 1_000
        )

      mark_ready(name, pid, fake_port)

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

      {pid, fake_port} =
        start_connected(name,
          port_commander: commander,
          output_retry_ms: 20,
          output_failure_ms: 1_000
        )

      :ok = Manager.subscribe(name)
      mark_ready(name, pid, fake_port)
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
      mark_ready(name, pid, port)
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

  describe "transport failure lifecycle" do
    test "spawn mode restarts the manager and downstream children through rest-for-one" do
      renderer_path = temporary_renderer_path()
      name = unique_name()
      parent = self()

      opener = fn _spec, _opts ->
        port = Port.open({:spawn, "cat 2>/dev/null"}, [:binary, {:packet, 4}])
        send(parent, {:spawn_port_opened, port})
        port
      end

      commander = fn _port, _batch, [:nosuspend] -> false end

      manager_child =
        {Manager,
         name: name,
         renderer_path: renderer_path,
         port_opener: opener,
         port_commander: commander,
         output_retry_ms: 60_000,
         output_failure_ms: 0}

      probe_child = %{
        id: :transport_failure_probe,
        start:
          {Agent, :start_link,
           [
             fn ->
               send(parent, {:probe_started, self()})
               :ready
             end
           ]}
      }

      {:ok, supervisor} =
        Supervisor.start_link([manager_child, probe_child], strategy: :rest_for_one)

      Process.unlink(supervisor)
      on_exit(fn -> stop_if_alive(supervisor) end)

      assert_receive {:spawn_port_opened, _first_port}
      assert_receive {:probe_started, first_probe}
      first_manager = Process.whereis(name)
      manager_ref = Process.monitor(first_manager)

      assert :unwritable = Manager.send_commands(name, [Protocol.encode_set_title("title")])
      retry_token = :sys.get_state(first_manager).output_pressure.retry_token
      send(first_manager, {:retry_frontend_output, retry_token})

      assert_receive {:DOWN, ^manager_ref, :process, ^first_manager,
                      :frontend_output_transport_failure}

      assert_receive {:spawn_port_opened, _replacement_port}
      assert_receive {:probe_started, replacement_probe}
      replacement_manager = Process.whereis(name)

      assert replacement_manager != first_manager
      assert replacement_probe != first_probe
      assert Process.alive?(replacement_manager)
      assert Process.alive?(replacement_probe)
    end

    test "a failed spawn-mode restart terminates the supervising generation" do
      renderer_path = temporary_renderer_path()
      name = unique_name()
      opens = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      opener = fn _spec, _opts ->
        case Agent.get_and_update(opens, fn count -> {count, count + 1} end) do
          0 -> Port.open({:spawn, "cat 2>/dev/null"}, [:binary, {:packet, 4}])
          _restart -> raise "replacement transport unavailable"
        end
      end

      manager_child =
        {Manager,
         name: name,
         renderer_path: renderer_path,
         port_opener: opener,
         port_commander: fn _port, _batch, [:nosuspend] -> false end,
         output_retry_ms: 60_000,
         output_failure_ms: 0}

      {:ok, supervisor} =
        Supervisor.start_link([manager_child],
          strategy: :rest_for_one,
          max_restarts: 1,
          max_seconds: 5
        )

      Process.unlink(supervisor)
      supervisor_ref = Process.monitor(supervisor)
      manager = Process.whereis(name)

      assert :unwritable = Manager.send_commands(name, [Protocol.encode_set_title("title")])
      retry_token = :sys.get_state(manager).output_pressure.retry_token
      send(manager, {:retry_frontend_output, retry_token})

      assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, :shutdown}
      assert Agent.get(opens, & &1) >= 2
      assert Process.whereis(name) == nil
    end

    @tag :heavy
    test "connected mode exits the BEAM with failure status" do
      script = ~S'''
      Application.put_env(:minga, :start_editor, true)
      {:ok, _apps} = Application.ensure_all_started(:telemetry)

      opener = fn _spec, _opts ->
        Port.open({:spawn, "cat 2>/dev/null"}, [:binary, {:packet, 4}])
      end

      {:ok, manager} =
        MingaEditor.Frontend.Manager.start_link(
          name: :isolated_transport_failure_manager,
          renderer_path: "/nonexistent",
          port_mode: :connected,
          port_opener: opener,
          port_commander: fn _port, _batch, [:nosuspend] -> false end,
          output_retry_ms: 1,
          output_failure_ms: 0
        )

      :unwritable =
        MingaEditor.Frontend.Manager.send_commands(manager, [
          MingaEditor.Frontend.Protocol.encode_set_title("timeout")
        ])

      receive do
      after
        2_000 -> System.halt(99)
      end
      '''

      {output, status} = run_isolated_elixir(script)

      assert status == 1

      assert [["Frontend output transport remained unwritable"]] =
               Regex.scan(~r/Frontend output transport remained unwritable/, output)
    end
  end

  describe "renderer shutdown" do
    # The fake renderer exits only after it reads renderer_shutdown, then takes
    # a moment to "restore the terminal" before writing its marker and exiting.
    @restoring_renderer """
    request=$(head -c 5 | od -An -tx1 | tr -d ' \\n')
    [ "$request" = "0000000114" ] || exit 3
    sleep 0.2
    echo restored > "$1"
    """

    @stuck_renderer "cat >/dev/null"

    test "stopping the manager asks a spawned renderer to exit and waits for it" do
      marker = Path.join(System.tmp_dir!(), "minga-renderer-restored-#{unique_integer()}")
      on_exit(fn -> File.rm(marker) end)
      name = unique_name()

      start_supervised!(
        {Manager,
         name: name,
         renderer_path: temporary_renderer_path(),
         port_opener: script_port_opener(@restoring_renderer, [marker])},
        id: name
      )

      assert_receive {:script_port, _port}
      :ok = stop_supervised(name)

      assert File.read(marker) == {:ok, "restored\n"}
    end

    test "stopping the manager closes the port when the renderer does not exit in time" do
      name = unique_name()

      start_supervised!(
        {Manager,
         name: name,
         renderer_path: temporary_renderer_path(),
         port_opener: script_port_opener(@stuck_renderer, []),
         renderer_exit_timeout_ms: 50},
        id: name
      )

      assert_receive {:script_port, port}

      log =
        capture_log(fn ->
          {elapsed_us, :ok} = :timer.tc(fn -> stop_supervised(name) end)
          assert elapsed_us >= 50_000
          assert elapsed_us < 2_000_000
        end)

      assert log =~ "Renderer did not exit within 50ms"
      assert Port.info(port) == nil
    end

    test "a connected frontend is not asked to exit" do
      name = unique_name()
      parent = self()

      commander = fn port, batch, [:nosuspend] ->
        send(parent, {:port_command, batch})
        Port.command(port, batch, [:nosuspend])
      end

      {_pid, _port} = start_connected(name, port_commander: commander)
      :ok = stop_supervised(name)

      refute_received {:port_command, <<0x14>>}
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

  defp mark_ready(server, pid, port) do
    send_port_data(pid, port, ready_packet(80, 24))
    assert Manager.ready?(server)
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

  defp unique_integer, do: System.unique_integer([:positive])

  # Opens a real spawned port with the manager's options, running `script` as
  # the renderer. The script's positional parameters are `args`.
  defp script_port_opener(script, args) do
    parent = self()

    fn _spec, opts ->
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [{:args, ["-c", script, "sh" | args]} | opts])

      send(parent, {:script_port, port})
      port
    end
  end

  defp temporary_renderer_path do
    path = Path.join(System.tmp_dir!(), "minga-renderer-#{System.unique_integer([:positive])}")
    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  end

  defp run_isolated_elixir(script) do
    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    code_path_args =
      :code.get_path()
      |> Enum.flat_map(fn path -> ["-pa", List.to_string(path)] end)

    System.cmd(elixir, code_path_args ++ ["-e", script], stderr_to_stdout: true)
  end
end
