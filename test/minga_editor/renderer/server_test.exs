defmodule MingaEditor.Renderer.ServerTest do
  @moduledoc """
  Focused tests for the standalone Renderer GenServer.

  Pipeline details are covered in render-pipeline tests. This file checks the server-level contract: coalescing telemetry, crash tolerance, writeback, and async-vs-sync dispatch.
  """

  # Registers a fake shell in the global shell registry for async-render opt-out coverage.
  use ExUnit.Case, async: false

  alias Minga.Frontend.Adapter.GUI.Caches, as: GUICaches
  alias Minga.RenderModel.Window.LineIdentity
  alias MingaEditor.Frontend.ResourcePolicy
  alias MingaEditor.Frontend.Manager
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.FrameIntent
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.WindowIntent
  alias MingaEditor.RenderPipeline.WorkspaceIntent
  alias MingaEditor.Shell.Runtime, as: ShellRuntime
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.Renderer.ObservedBuffers
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.State.Render
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.Renderer.RenderWindow, as: Window
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.FontRegistry

  @async_render_timeout 5_000

  defmodule RecoveryForwarder do
    @moduledoc false

    use GenServer

    alias MingaEditor.Frontend.Manager
    alias MingaEditor.Renderer.Server, as: RendererServer

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    @spec init(keyword()) :: {:ok, keyword()}
    def init(opts) do
      :ok = Manager.subscribe(Keyword.fetch!(opts, :manager))
      {:ok, opts}
    end

    @impl true
    def handle_info({:minga_input, {:ready, width, height}}, opts) do
      if Agent.get(Keyword.fetch!(opts, :active), & &1) do
        :ok =
          RendererServer.reset_connection(
            Keyword.fetch!(opts, :renderer),
            Keyword.fetch!(opts, :intent),
            Keyword.fetch!(opts, :frame_seq)
          )

        send(Keyword.fetch!(opts, :parent), {:replayed_ready, self(), width, height})
      end

      {:noreply, opts}
    end

    def handle_info({:minga_input, {:frame_applied, generation, frame_seq}} = message, opts) do
      RendererServer.frame_status(
        Keyword.fetch!(opts, :renderer),
        {:frame_applied, generation, frame_seq}
      )

      send(Keyword.fetch!(opts, :parent), {:forwarded, self(), message})
      {:noreply, opts}
    end

    def handle_info(_message, opts), do: {:noreply, opts}
  end

  setup do
    MingaEditor.Shell.Registry.reset_for_test()
    MingaEditor.Shell.Registry.seed_builtin()

    :ok =
      MingaEditor.Shell.Registry.register({:extension, :fake_shell}, %{
        id: :fake,
        module: MingaEditor.Test.FakeShell,
        display_name: "Fake Shell",
        description: "Test shell",
        default?: false,
        capabilities: []
      })

    on_exit(fn ->
      MingaEditor.Shell.Registry.reset_for_test()
      MingaEditor.Shell.Registry.seed_builtin()
    end)

    :ok
  end

  test "coalescing replaces older pending snapshots and emits telemetry" do
    renderer = start_renderer(self())
    attach_coalesce_handler()
    park_in_flight(renderer)

    RendererServer.cast_snapshot(renderer, stub_intent(), 1)
    RendererServer.cast_snapshot(renderer, stub_intent(), 2)
    RendererServer.cast_snapshot(renderer, stub_intent(), 3)

    assert_receive {:tel, [:minga, :render, :coalesced], %{count: 1},
                    %{dropped_seq: 1, new_seq: 2}}

    assert_receive {:tel, [:minga, :render, :coalesced], %{count: 1},
                    %{dropped_seq: 2, new_seq: 3}}
  end

  test "pipeline crashes drop frames without killing the server" do
    renderer = start_renderer(self(), pipeline: fn _input -> raise "boom" end)

    RendererServer.cast_snapshot(renderer, stub_intent(), 42)

    refute renderer_busy?(renderer)
    assert Process.alive?(renderer)
  end

  test "pipeline failure cannot commit its locally allocated font registry" do
    parent = self()

    pipeline = fn input ->
      {_id, allocated, true} =
        FontRegistry.get_or_register(input.font_registry, "Failed Fallback")

      send(parent, {:failed_font_registry, allocated})
      raise "boom after font allocation"
    end

    renderer = start_renderer(self(), pipeline: pipeline)
    RendererServer.cast_snapshot(renderer, stub_intent(), 43)

    assert_receive {:failed_font_registry, failed_registry}, @async_render_timeout
    assert FontRegistry.lookup(failed_registry, "Failed Fallback") == 1

    refute renderer_busy?(renderer)
    assert :sys.get_state(renderer).font_registry == FontRegistry.new()
  end

  test "retryable rejection reuses font ids and restores registration order" do
    parent = self()

    pipeline = fn input ->
      send(
        parent,
        {:font_registry_probe, input.frame_seq,
         FontRegistry.pending_registrations(input.font_registry)}
      )

      case input.frame_seq do
        20 ->
          {_id, registry, true} =
            FontRegistry.get_or_register(input.font_registry, "First Fallback")

          {_id, registry, true} = FontRegistry.get_or_register(registry, "Second Fallback")
          Input.with_font_registry(input, FontRegistry.mark_registered(registry))

        _ ->
          input
      end
    end

    renderer = start_ack_renderer(self(), pipeline: pipeline)
    RendererServer.cast_snapshot(renderer, stub_intent(), 20)
    assert_receive {:font_registry_probe, 20, []}, @async_render_timeout

    RendererServer.cast_snapshot(renderer, stub_intent(), 21)
    reject_base_sequence_mismatch(renderer, 1, 20, 0)

    assert_receive {:font_registry_probe, 21, [{1, "First Fallback"}, {2, "Second Fallback"}]},
                   @async_render_timeout

    registry = :sys.get_state(renderer).font_registry
    assert FontRegistry.lookup(registry, "First Fallback") == 1
    assert FontRegistry.lookup(registry, "Second Fallback") == 2
  end

  test "synchronous stale-buffer retries stop at the configured bound" do
    attempts = start_supervised!({Agent, fn -> 0 end})

    pipeline = fn _input ->
      Agent.update(attempts, &(&1 + 1))
      raise MingaEditor.Renderer.StaleBufferError, buffer: self(), expected_version: 0
    end

    renderer = start_renderer(self(), pipeline: pipeline)

    assert {:error, %MingaEditor.Renderer.StaleBufferError{}} =
             RendererServer.render_sync(renderer, stub_intent(), 42)

    assert Agent.get(attempts, & &1) == 4
    refute renderer_busy?(renderer)
  end

  test "exhausted async stale retries advance to the latest pending intent" do
    parent = self()

    pipeline = fn input ->
      send(parent, {:stale_retry_attempt, input.frame_seq})

      case input.frame_seq do
        10 ->
          raise MingaEditor.Renderer.StaleBufferError, buffer: self(), expected_version: 0

        11 ->
          input
      end
    end

    renderer = start_renderer(self(), pipeline: pipeline)
    :ok = :sys.suspend(renderer)
    RendererServer.cast_snapshot(renderer, stub_intent(), 10)
    RendererServer.cast_snapshot(renderer, stub_intent(), 11)
    :ok = :sys.resume(renderer)

    for _attempt <- 1..4 do
      assert_receive {:stale_retry_attempt, 10}, @async_render_timeout
    end

    assert_receive {:stale_retry_attempt, 11}, @async_render_timeout
    assert_receive {:render_done, %RenderReceipt{frame_seq: 11}}, @async_render_timeout
    refute renderer_busy?(renderer)
  end

  test "successful async render sends writeback and emits a frame" do
    renderer = start_renderer(self(), pipeline: &emit_commit_frame/1)
    state = build_editor_state(:tui, nil)
    snapshot = Input.from_editor_state(state)
    frame_ref = Minga.Test.HeadlessPort.prepare_await(state.frontend.port_manager)

    RendererServer.cast_snapshot(renderer, snapshot.intent, 123)

    assert {:ok, _screen} =
             Minga.Test.HeadlessPort.collect_frame(frame_ref, @async_render_timeout)

    assert_receive {:render_done, %RenderReceipt{frame_seq: 123}},
                   @async_render_timeout

    refute renderer_busy?(renderer)
  end

  test "pending snapshots inherit the latest emitted caches before rendering" do
    parent = self()
    renderer = start_renderer(parent, pipeline: cache_probe_pipeline(parent))
    initial_caches = %Caches{last_emitted_frame_seq: 10}
    in_flight = stub_snapshot() |> Map.put(:caches, initial_caches) |> intent_of()
    pending = stub_snapshot() |> Map.put(:caches, initial_caches) |> intent_of()

    token = make_ref()

    :sys.replace_state(renderer, fn state ->
      state
      |> RendererState.schedule_frame(FrameAttempt.new(in_flight, 11, 0), token)
      |> elem_from_coalesce(FrameAttempt.new(pending, 12, 0))
    end)

    send(renderer, {:do_render, token})

    assert_receive {:pipeline_input, 11, 0}, @async_render_timeout
    assert_receive {:pipeline_input, 12, 11}, @async_render_timeout

    assert_receive {:render_done, %RenderReceipt{frame_seq: 11}},
                   @async_render_timeout

    assert_receive {:render_done, %RenderReceipt{frame_seq: 12}},
                   @async_render_timeout
  end

  test "in-flight and pending structural edits rebase through renderer-owned lineage" do
    state = build_editor_state(:tui, nil, "a\nb\nc")
    snapshot = Input.from_editor_state(state)
    buffer = state.workspace.buffers.active
    renderer = start_ack_renderer(self(), pipeline: lineage_probe_pipeline(self()))

    RendererServer.cast_snapshot(renderer, snapshot.intent, 70)
    assert_receive {:lineage_probe, 70, nil, 0, [0, 1, 2], 0}, @async_render_timeout

    :ok = Minga.Buffer.Process.move_to(buffer, {0, 0})
    :ok = Minga.Buffer.Process.insert_text(buffer, "new\n")
    RendererServer.cast_snapshot(renderer, snapshot.intent, 71)
    RendererServer.frame_status(renderer, {:frame_applied, 1, 70})

    assert_receive {:lineage_probe, 71, [3, 0, 1, 2], 1, [3, 0, 1, 2], 1},
                   @async_render_timeout
  end

  test "rejection rehydrates lineage in a fresh content epoch" do
    state = build_editor_state(:tui, nil, "a\nb")
    snapshot = Input.from_editor_state(state)
    buffer = state.workspace.buffers.active
    renderer = start_ack_renderer(self(), pipeline: lineage_probe_pipeline(self()))

    RendererServer.cast_snapshot(renderer, snapshot.intent, 80)
    assert_receive {:lineage_probe, 80, nil, 0, [0, 1], 0}, @async_render_timeout

    :ok = Minga.Buffer.Process.move_to(buffer, {0, 0})
    :ok = Minga.Buffer.Process.insert_text(buffer, "new\n")
    RendererServer.cast_snapshot(renderer, snapshot.intent, 81)
    reject_base_sequence_mismatch(renderer, 1, 80, 0)
    assert_receive {:lineage_probe, 81, nil, 0, [0, 1, 2], 1}, @async_render_timeout
    RendererServer.frame_status(renderer, {:frame_applied, 2, 81})
  end

  test "pipeline failure keeps renderer-consumed lineage for pending replay" do
    state = build_editor_state(:tui, nil, "a\nb")
    snapshot = Input.from_editor_state(state)
    buffer = state.workspace.buffers.active
    failure_mode = start_supervised!({Agent, fn -> :succeed end})

    renderer =
      start_renderer(self(), pipeline: failing_lineage_probe_pipeline(self(), failure_mode))

    RendererServer.cast_snapshot(renderer, snapshot.intent, 89)
    assert_receive {:lineage_probe, 89, nil, 0, [0, 1], 0}, @async_render_timeout
    assert_receive {:render_done, %RenderReceipt{frame_seq: 89}}, @async_render_timeout

    :ok = Minga.Buffer.Process.move_to(buffer, {0, 0})
    :ok = Minga.Buffer.Process.insert_text(buffer, "new\n")
    Agent.update(failure_mode, fn _ -> :fail_once end)

    token = make_ref()

    :sys.replace_state(renderer, fn renderer_state ->
      renderer_state
      |> RendererState.schedule_frame(FrameAttempt.new(snapshot.intent, 90, 0), token)
      |> elem_from_coalesce(FrameAttempt.new(snapshot.intent, 91, 0))
    end)

    send(renderer, {:do_render, token})

    assert_receive {:lineage_probe, 90, [2, 0, 1], 1, [2, 0, 1], 1}, @async_render_timeout
    assert_receive {:lineage_probe, 91, [2, 0, 1], 1, [2, 0, 1], 1}, @async_render_timeout
  end

  test "idle renderer uses its latest caches when the editor writeback is still stale" do
    parent = self()
    renderer = start_renderer(parent, pipeline: cache_probe_pipeline(parent))
    stale_editor_snapshot = %{stub_snapshot() | caches: %Caches{last_emitted_frame_seq: 10}}

    :sys.replace_state(renderer, fn state ->
      %{state | caches: %Caches{last_emitted_frame_seq: 11}}
    end)

    RendererServer.cast_snapshot(renderer, stale_editor_snapshot.intent, 12)

    assert_receive {:pipeline_input, 12, 11}, @async_render_timeout

    assert_receive {:render_done, %RenderReceipt{frame_seq: 12}},
                   @async_render_timeout
  end

  test "renderer ignores reset cache payloads from Editor intents" do
    parent = self()
    renderer = start_renderer(parent, pipeline: cache_probe_pipeline(parent))

    reset_snapshot = %{
      stub_snapshot()
      | caches: %Caches{last_emitted_frame_seq: 0, recovery_generation: 2}
    }

    :sys.replace_state(renderer, fn state ->
      %{state | caches: %Caches{last_emitted_frame_seq: 11}}
    end)

    RendererServer.cast_snapshot(renderer, reset_snapshot.intent, 12)

    assert_receive {:pipeline_input, 12, 11}, @async_render_timeout

    assert_receive {:render_done, %RenderReceipt{frame_seq: 12}},
                   @async_render_timeout
  end

  test "frame credit phase serializes scheduled, awaiting ack, successor, and idle" do
    renderer = start_ack_renderer(self())
    assert :sys.get_state(renderer).frame_credit == :idle

    RendererServer.cast_snapshot(renderer, stub_intent(), 10)
    assert_receive {:ack_pipeline, 10, 1, 0, true}, @async_render_timeout

    assert {:awaiting_ack, lease10, nil} = :sys.get_state(renderer).frame_credit
    assert lease10.attempt.seq == 10

    RendererServer.cast_snapshot(renderer, stub_intent(), 11)
    RendererServer.cast_snapshot(renderer, stub_intent(), 12)

    assert {:awaiting_ack, ^lease10, %FrameAttempt{seq: 12}} =
             :sys.get_state(renderer).frame_credit

    refute_receive {:ack_pipeline, 11, _, _, _}, 50
    refute_receive {:ack_pipeline, 12, _, _, _}, 50

    RendererServer.frame_status(renderer, {:frame_applied, 1, 10})
    assert_receive {:render_done, %RenderReceipt{frame_seq: 10}}, @async_render_timeout
    assert_receive {:ack_pipeline, 12, 1, 10, false}, @async_render_timeout

    RendererServer.frame_status(renderer, {:frame_applied, 1, 12})
    assert_receive {:render_done, %RenderReceipt{frame_seq: 12}}, @async_render_timeout

    assert :sys.get_state(renderer).frame_credit == :idle
    refute RendererServer.rendering?(renderer)
  end

  describe "frame acknowledgement credit" do
    test "rest-for-one renderer replacement reserves beyond the surviving connection and acknowledges its first keyframe" do
      parent = self()
      manager_name = unique_process_name(:generation_manager)
      renderer_name = unique_process_name(:generation_renderer)
      active = start_supervised!({Agent, fn -> false end}, id: make_ref())

      opener = fn _spec, _opts ->
        port = Port.open({:spawn, "cat 2>/dev/null"}, [:binary, {:packet, 4}])
        send(parent, {:recovery_port, port})
        port
      end

      commander = fn _port, batch, [:nosuspend] ->
        send(parent, {:wire_batch, batch})
        true
      end

      manager_child =
        {Manager,
         name: manager_name,
         renderer_path: "/nonexistent",
         port_mode: :connected,
         port_opener: opener,
         port_commander: commander}

      renderer_child =
        {RendererServer,
         name: renderer_name,
         editor_pid: parent,
         frontend_manager: manager_name,
         pipeline: connected_ack_pipeline(manager_name),
         require_ack?: true,
         ack_timeout_ms: 60_000}

      forwarder_child = %{
        id: RecoveryForwarder,
        start:
          {RecoveryForwarder, :start_link,
           [
             [
               manager: manager_name,
               renderer: renderer_name,
               active: active,
               parent: parent,
               intent: stub_intent(),
               frame_seq: 60
             ]
           ]}
      }

      {:ok, supervisor} =
        Supervisor.start_link([manager_child, renderer_child, forwarder_child],
          strategy: :rest_for_one
        )

      Process.unlink(supervisor)
      on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)

      assert_receive {:recovery_port, port}, @async_render_timeout
      manager = Process.whereis(manager_name)
      send(manager, {port, {:data, ready_packet(80, 24)}})
      assert Manager.ready?(manager_name)

      assert :accepted =
               Manager.send_render_commands(manager_name, connected_frame_commands(50, 0, 5))

      assert_receive {:wire_batch, _generation_five_batch}, @async_render_timeout
      send(manager, {port, {:data, <<0x0A, 5::32, 50::32>>}})
      assert Manager.output_pressure(manager_name).last_applied_generation == 5

      Agent.update(active, fn _ -> true end)
      first_renderer = Process.whereis(renderer_name)
      first_ref = Process.monitor(first_renderer)
      Process.exit(first_renderer, :kill)

      assert_receive {:DOWN, ^first_ref, :process, ^first_renderer, :killed},
                     @async_render_timeout

      assert_receive {:replayed_ready, replacement_forwarder, 80, 24}, @async_render_timeout
      replacement_renderer = Process.whereis(renderer_name)
      assert replacement_renderer != first_renderer

      assert_receive {:wire_batch, recovery_batch}, @async_render_timeout
      assert {60, 0, recovery_generation} = frame_header(recovery_batch)
      assert recovery_generation > 5

      send(manager, {port, {:data, <<0x0A, 5::32, 50::32>>}})
      refute_receive {:forwarded, ^replacement_forwarder, _message}, 30

      send(manager, {port, {:data, <<0x0A, recovery_generation::32, 60::32>>}})

      assert_receive {:forwarded, ^replacement_forwarder,
                      {:minga_input, {:frame_applied, ^recovery_generation, 60}}},
                     @async_render_timeout

      assert_receive {:render_done, %RenderReceipt{frame_seq: 60, keyframe?: true}},
                     @async_render_timeout

      refute_receive {:wire_batch, _timeout_catch_up}, 50
      assert RendererServer.acknowledgement_state(renderer_name) == {recovery_generation, 60}

      send(manager, {port, {:data, ready_packet(80, 24)}})
      assert_receive {:replayed_ready, ^replacement_forwarder, 80, 24}, @async_render_timeout
      assert_receive {:wire_batch, duplicate_ready_batch}, @async_render_timeout
      assert {60, 0, duplicate_ready_generation} = frame_header(duplicate_ready_batch)
      assert duplicate_ready_generation > recovery_generation

      assert RendererServer.request_recovery(renderer_name, duplicate_ready_generation, 0) ==
               :recovery_started

      assert_receive {:wire_batch, concurrent_recovery_batch}, @async_render_timeout

      assert {concurrent_frame_seq, 0, concurrent_recovery_generation} =
               frame_header(concurrent_recovery_batch)

      assert concurrent_frame_seq > 60
      assert concurrent_recovery_generation > duplicate_ready_generation

      send(manager, {port, {:data, <<0x0A, duplicate_ready_generation::32, 60::32>>}})
      refute_receive {:forwarded, ^replacement_forwarder, _message}, 30

      send(
        manager,
        {port, {:data, <<0x0A, concurrent_recovery_generation::32, concurrent_frame_seq::32>>}}
      )

      assert_receive {:render_done, %RenderReceipt{frame_seq: ^concurrent_frame_seq}},
                     @async_render_timeout

      assert RendererServer.acknowledgement_state(renderer_name) ==
               {concurrent_recovery_generation, concurrent_frame_seq}
    end

    test "only a matching frame acknowledgement promotes every pending GUI window delta" do
      renderer =
        start_ack_renderer(self(), pipeline: pending_window_delta_probe_pipeline(self()))

      RendererServer.cast_snapshot(renderer, stub_intent(), 9)
      assert_receive {:pending_window_deltas, 9, [1, 2]}, @async_render_timeout

      assert {:awaiting_ack, lease, nil} = :sys.get_state(renderer).frame_credit
      assert lease.output.caches.adapter_gui_caches.pending_window_delta_ids == MapSet.new([1, 2])

      RendererServer.frame_status(renderer, {:frame_applied, 2, 9})
      RendererServer.frame_status(renderer, {:frame_applied, 1, 8})

      unmatched = :sys.get_state(renderer)
      assert unmatched.caches.adapter_gui_caches.last_window_content_fps == %{}
      assert {:awaiting_ack, ^lease, nil} = unmatched.frame_credit

      RendererServer.frame_status(renderer, {:frame_applied, 1, 9})
      assert_receive {:render_done, %RenderReceipt{frame_seq: 9}}, @async_render_timeout

      committed = :sys.get_state(renderer).caches.adapter_gui_caches
      assert committed.last_window_content_fps == %{1 => 101, 2 => 202}
      assert committed.pending_window_delta_ids == MapSet.new()
    end

    test "apply advances the base while duplicate, out-of-order, stale, and wrong-generation statuses do not" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 10)
      assert_receive {:ack_pipeline, 10, 1, 0, true}, @async_render_timeout

      RendererServer.cast_snapshot(renderer, stub_intent(), 11)
      RendererServer.cast_snapshot(renderer, stub_intent(), 12)

      RendererServer.frame_status(renderer, {:frame_applied, 2, 10})
      RendererServer.frame_status(renderer, {:frame_applied, 1, 9})
      reject_base_sequence_mismatch(renderer, 1, 10, 99)
      assert RendererServer.acknowledgement_state(renderer) == {1, 0}
      refute_receive {:ack_pipeline, _, _, _, _}, 50

      RendererServer.frame_status(renderer, {:frame_applied, 1, 10})

      assert_receive {:render_done, %RenderReceipt{frame_seq: 10, keyframe?: true}},
                     @async_render_timeout

      assert_receive {:ack_pipeline, 12, 1, 10, false}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {1, 10}

      RendererServer.frame_status(renderer, {:frame_applied, 1, 10})
      reject_base_sequence_mismatch(renderer, 0, 12, 10)
      assert RendererServer.acknowledgement_state(renderer) == {1, 10}
      refute_receive {:render_done, %RenderReceipt{frame_seq: 12}}, 50
    end

    test "acknowledgement timeout retries the latest pending frame as a fresh-generation keyframe" do
      renderer =
        start_ack_renderer(self(), pipeline: first_generation_pending_delta_pipeline(self()))

      RendererServer.cast_snapshot(renderer, stub_intent(), 10)
      assert_receive {:ack_pipeline, 10, 1, 0, true}, @async_render_timeout
      assert pending_lease_window_ids(renderer) == MapSet.new([1, 2])
      RendererServer.cast_snapshot(renderer, stub_intent(), 11)

      send(renderer, {:frame_ack_timeout, 1, 10})

      assert_receive {:ack_pipeline, 11, 2, 0, true}, @async_render_timeout
      assert pending_lease_window_ids(renderer) == MapSet.new()
      assert :sys.get_state(renderer).caches.adapter_gui_caches.last_window_content_fps == %{}
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
      refute_receive {:render_done, %RenderReceipt{frame_seq: 10}}, 50
    end

    test "late acknowledgement from a timed-out generation cannot release current credit" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 20)
      assert_receive {:ack_pipeline, 20, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_intent(), 21)
      send(renderer, {:frame_ack_timeout, 1, 20})
      assert_receive {:ack_pipeline, 21, 2, 0, true}, @async_render_timeout

      RendererServer.frame_status(renderer, {:frame_applied, 1, 20})
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
      refute_receive {:render_done, %RenderReceipt{frame_seq: 20}}, 50

      RendererServer.frame_status(renderer, {:frame_applied, 2, 21})
      assert_receive {:render_done, %RenderReceipt{frame_seq: 21}}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {2, 21}
    end

    test "normal acknowledgement makes its queued timeout message harmless" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 30)
      assert_receive {:ack_pipeline, 30, 1, 0, true}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 1, 30})
      assert_receive {:render_done, %RenderReceipt{frame_seq: 30}}, @async_render_timeout

      send(renderer, {:frame_ack_timeout, 1, 30})
      refute RendererServer.rendering?(renderer)
      assert RendererServer.acknowledgement_state(renderer) == {1, 30}
      refute_receive {:ack_pipeline, _, _, _, _}, 50

      RendererServer.cast_snapshot(renderer, stub_intent(), 31)
      assert_receive {:ack_pipeline, 31, 1, 30, false}, @async_render_timeout
    end

    test "retryable rejection renders only latest pending intent as a fresh-generation keyframe" do
      renderer =
        start_ack_renderer(self(), pipeline: first_generation_pending_delta_pipeline(self()))

      RendererServer.cast_snapshot(renderer, stub_intent(), 20)
      assert_receive {:ack_pipeline, 20, 1, 0, true}, @async_render_timeout
      assert pending_lease_window_ids(renderer) == MapSet.new([1, 2])
      RendererServer.cast_snapshot(renderer, stub_intent(), 21)

      RendererServer.frame_status(
        renderer,
        {:frame_rejected, 1, 20, 0, :base_sequence_mismatch, :retryable_recovery}
      )

      assert_receive {:ack_pipeline, 21, 2, 0, true}, @async_render_timeout
      assert pending_lease_window_ids(renderer) == MapSet.new()
      assert :sys.get_state(renderer).caches.adapter_gui_caches.last_window_content_fps == %{}
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
      refute_receive {:ack_pipeline, _, 3, _, _}, 50
      refute_receive {:render_done, %RenderReceipt{frame_seq: 20}}, 50
    end

    test "decoded retryable frame rejection reaches renderer recovery" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 20)
      assert_receive {:ack_pipeline, 20, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_intent(), 21)

      assert {:ok, decoded} =
               MingaEditor.Frontend.Protocol.decode_event(<<0x0B, 1::32, 20::32, 0::32, 4, 1>>)

      assert decoded ==
               {:frame_rejected, 1, 20, 0, :base_sequence_mismatch, :retryable_recovery}

      state = build_editor_state(:tui, renderer)
      assert {:noreply, ^state} = MingaEditor.handle_info({:minga_input, decoded}, state)

      assert_receive {:ack_pipeline, 21, 2, 0, true}, @async_render_timeout
      refute_receive {:render_done, %RenderReceipt{frame_seq: 20}}, 50
    end

    test "terminal resource rejection cancels credit, preserves last good, and ignores stale duplicates" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 10)
      assert_receive {:ack_pipeline, 10, 1, 0, true}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 1, 10})
      assert_receive {:render_done, %RenderReceipt{frame_seq: 10}}, @async_render_timeout

      RendererServer.cast_snapshot(renderer, stub_intent(), 11)
      assert_receive {:ack_pipeline, 11, 1, 10, false}, @async_render_timeout

      RendererServer.frame_status(
        renderer,
        {:frame_rejected, 1, 12, 10, :resource_policy, :terminal_frontend_failure}
      )

      assert RendererServer.acknowledgement_state(renderer) == {1, 10}
      assert RendererServer.rendering?(renderer)
      assert RendererServer.terminal_failure(renderer) == nil

      terminal = {:frame_rejected, 1, 11, 10, :resource_policy, :terminal_frontend_failure}
      RendererServer.frame_status(renderer, terminal)

      refute RendererServer.rendering?(renderer)
      assert RendererServer.acknowledgement_state(renderer) == {1, 10}

      assert %{generation: 1, frame_seq: 11, last_good_frame_seq: 10, reason: :resource_policy} =
               RendererServer.terminal_failure(renderer)

      refute_receive {:render_done, %RenderReceipt{frame_seq: 11}}, 50

      RendererServer.frame_status(renderer, terminal)

      RendererServer.frame_status(
        renderer,
        {:frame_rejected, 0, 11, 10, :resource_policy, :terminal_frontend_failure}
      )

      assert RendererServer.acknowledgement_state(renderer) == {1, 10}
      refute_receive {:ack_pipeline, _, _, _, _}, 50
    end

    test "identical terminal intent stays blocked until capability state changes" do
      renderer = start_ack_renderer(self())
      snapshot = stub_snapshot()
      intent = snapshot.intent

      RendererServer.cast_snapshot(renderer, intent, 20)
      assert_receive {:ack_pipeline, 20, 1, 0, true}, @async_render_timeout

      RendererServer.frame_status(
        renderer,
        {:frame_rejected, 1, 20, 0, :resource_policy, :terminal_frontend_failure}
      )

      refute RendererServer.rendering?(renderer)
      RendererServer.cast_snapshot(renderer, intent, 21)
      refute_receive {:ack_pipeline, 21, _, _, _}, 50

      changed =
        put_frame(snapshot, %{
          snapshot.intent.frame
          | capabilities: %{snapshot.intent.frame.capabilities | semantic_ui: true}
        })

      RendererServer.cast_snapshot(renderer, changed.intent, 22)
      assert_receive {:ack_pipeline, 22, 1, 0, true}, @async_render_timeout
      assert RendererServer.terminal_failure(renderer) == nil
    end

    test "adapted retry consumes only matching evidence and renders the changed intent" do
      renderer = start_ack_renderer(self(), pipeline: adaptation_probe_pipeline(self()))

      snapshot = stub_snapshot()
      policy = ResourcePolicy.new(1, 64 * 1_048_576, 0, 0)

      snapshot =
        put_frame(snapshot, %{
          snapshot.intent.frame
          | capabilities: %{snapshot.intent.frame.capabilities | resource_policy: policy}
        })

      rejected_intent = snapshot.intent

      adapted_snapshot =
        put_frame(snapshot, %{
          snapshot.intent.frame
          | capabilities: %{snapshot.intent.frame.capabilities | semantic_ui: true}
        })

      adapted_intent = adapted_snapshot.intent

      RendererServer.cast_snapshot(renderer, rejected_intent, 30)
      assert_receive {:adaptation_pipeline, 30, 1, 0, true, false}, @async_render_timeout

      assert RendererServer.record_adaptation(
               renderer,
               1,
               30,
               :frame_bytes,
               1_000,
               1_000,
               adapted_intent
             ) == :error

      assert RendererServer.record_adaptation(
               renderer,
               1,
               30,
               :frame_commands,
               1_000,
               800,
               adapted_intent
             ) == :error

      assert RendererServer.record_adaptation(
               renderer,
               2,
               30,
               :frame_bytes,
               1_000,
               800,
               adapted_intent
             ) == :error

      assert RendererServer.record_adaptation(
               renderer,
               1,
               30,
               :frame_bytes,
               1_000,
               800,
               rejected_intent
             ) == :error

      assert RendererServer.record_adaptation(
               renderer,
               1,
               30,
               :frame_bytes,
               1_000,
               800,
               adapted_intent
             ) == :ok

      RendererServer.frame_status(
        renderer,
        {:frame_rejected, 1, 30, 0, :resource_policy, :adapted_retry}
      )

      assert_receive {:adaptation_pipeline, retry_seq, 2, 0, true, true},
                     @async_render_timeout

      assert retry_seq > 30
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}

      RendererServer.frame_status(
        renderer,
        {:frame_rejected, 2, retry_seq, 0, :resource_policy, :adapted_retry}
      )

      refute RendererServer.rendering?(renderer)

      assert %{frame_seq: ^retry_seq, reason: :resource_policy} =
               RendererServer.terminal_failure(renderer)

      refute_receive {:adaptation_pipeline, _, 3, _, _, _}, 50
    end

    test "matching recovery preserves the latest coalesced intent and rejects delayed duplicates" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 30)
      assert_receive {:ack_pipeline, 30, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_intent(), 31)

      assert RendererServer.request_recovery(renderer, 1, 99) == :stale
      assert RendererServer.acknowledgement_state(renderer) == {1, 0}

      assert RendererServer.request_recovery(renderer, 1, 0) == :recovery_started
      assert_receive {:ack_pipeline, 31, 2, 0, true}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}

      assert RendererServer.request_recovery(renderer, 1, 0) == :stale
      assert RendererServer.request_recovery(renderer, 1, 0) == :stale
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
      refute_received {:ack_pipeline, _, 3, _, _}
    end

    test "matching recovery can replace a scheduled attempt before rendering begins" do
      renderer = start_ack_renderer(self())
      park_in_flight(renderer)

      assert RendererServer.request_recovery(renderer, 1, 0) == :recovery_started
      assert_receive {:ack_pipeline, retry_seq, 2, 0, true}, @async_render_timeout
      assert retry_seq > 0
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
    end

    test "recovery request while idle is stale" do
      renderer = start_ack_renderer(self())

      assert RendererServer.request_recovery(renderer, 1, 0) == :stale
      assert RendererServer.acknowledgement_state(renderer) == {1, 0}
      refute_received {:ack_pipeline, _, _, _, _}
    end

    test "recovery request after acknowledgement is stale" do
      renderer = start_ack_renderer(self())
      RendererServer.cast_snapshot(renderer, stub_intent(), 40)
      assert_receive {:ack_pipeline, 40, 1, 0, true}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 1, 40})
      assert_receive {:render_done, %RenderReceipt{frame_seq: 40}}, @async_render_timeout

      assert RendererServer.request_recovery(renderer, 1, 40) == :stale
      assert RendererServer.acknowledgement_state(renderer) == {1, 40}
      refute_received {:ack_pipeline, _, 2, _, _}
    end

    test "recovery request after terminal failure is stale" do
      renderer = start_ack_renderer(self())
      RendererServer.cast_snapshot(renderer, stub_intent(), 50)
      assert_receive {:ack_pipeline, 50, 1, 0, true}, @async_render_timeout

      RendererServer.frame_status(
        renderer,
        {:frame_rejected, 1, 50, 0, :resource_policy, :terminal_frontend_failure}
      )

      assert %{frame_seq: 50} = RendererServer.terminal_failure(renderer)
      assert RendererServer.request_recovery(renderer, 1, 0) == :stale
      assert RendererServer.acknowledgement_state(renderer) == {1, 0}
      refute_received {:ack_pipeline, _, 2, _, _}
    end

    test "recovery request from a replaced connection cannot reset its successor" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 60)
      assert_receive {:ack_pipeline, 60, 1, 0, true}, @async_render_timeout

      assert :ok = RendererServer.reset_connection(renderer, stub_intent(), 61)
      assert_receive {:ack_pipeline, 61, 2, 0, true}, @async_render_timeout

      assert RendererServer.request_recovery(renderer, 1, 0) == :stale
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
      refute_received {:ack_pipeline, _, 3, _, _}
    end

    test "Editor forwards keyframe recovery correlation unchanged" do
      renderer = start_ack_renderer(self())
      state = build_editor_state(:tui, renderer)

      RendererServer.cast_snapshot(renderer, stub_intent(), 70)
      assert_receive {:ack_pipeline, 70, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_intent(), 71)

      message = {:minga_input, {:request_keyframe, 0, 1}}
      assert {:noreply, ^state} = MingaEditor.handle_info(message, state)

      assert_receive {:ack_pipeline, 71, 2, 0, true}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
    end

    test "connection reset clears stale retry exhaustion before recovery" do
      parent = self()
      attempts = start_supervised!({Agent, fn -> 0 end})

      pipeline = fn input ->
        attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
        send(parent, {:reset_retry_attempt, attempt})

        case attempt do
          1 ->
            raise MingaEditor.Renderer.StaleBufferError,
              buffer: self(),
              expected_version: 0

          2 ->
            input
        end
      end

      renderer = start_renderer(self(), pipeline: pipeline)

      :sys.replace_state(
        renderer,
        &%{
          &1
          | frame_credit: {:scheduled, make_ref(), FrameAttempt.new(stub_intent(), 59, 0), 3, nil}
        }
      )

      :ok = RendererServer.reset_connection(renderer, stub_intent(), 60)

      assert_receive {:reset_retry_attempt, 1}, @async_render_timeout
      assert_receive {:reset_retry_attempt, 2}, @async_render_timeout
      assert_receive {:render_done, %RenderReceipt{frame_seq: 60}}, @async_render_timeout
    end

    test "connection reset abandons outstanding credit and resumes from a base-zero keyframe" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 50)
      assert_receive {:ack_pipeline, 50, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_intent(), 51)

      :ok = RendererServer.reset_connection(renderer, stub_intent(), 60)
      assert_receive {:ack_pipeline, 60, 2, 0, true}, @async_render_timeout
      refute_receive {:ack_pipeline, 51, _, _, _}, 50

      RendererServer.frame_status(renderer, {:frame_applied, 1, 50})
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
      refute_receive {:render_done, %RenderReceipt{frame_seq: 50}}, 50

      RendererServer.frame_status(renderer, {:frame_applied, 2, 60})
      assert_receive {:render_done, %RenderReceipt{frame_seq: 60}}, @async_render_timeout

      RendererServer.cast_snapshot(renderer, stub_intent(), 61)
      assert_receive {:ack_pipeline, 61, 2, 60, false}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {2, 60}
    end

    test "stale render work queued by pending advance is harmless after connection reset" do
      renderer = start_ack_renderer(self())
      snapshot = stub_snapshot()

      RendererServer.cast_snapshot(renderer, snapshot.intent, 100)
      assert_receive {:ack_pipeline, 100, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, snapshot.intent, 101)

      :ok = :sys.suspend(renderer)
      RendererServer.frame_status(renderer, {:frame_applied, 1, 100})

      call_ref = make_ref()
      intent = snapshot.intent

      send(
        renderer,
        {:"$gen_call", {self(), call_ref},
         {:reset_connection, intent, 102, System.monotonic_time()}}
      )

      :ok = :sys.resume(renderer)
      assert_receive {^call_ref, :ok}, @async_render_timeout
      assert_receive {:ack_pipeline, 102, 2, 0, true}, @async_render_timeout
      refute_receive {:ack_pipeline, 101, _, _, _}, 50
      refute_receive {:ack_pipeline, 102, 3, _, _}, 50

      monitor = Process.monitor(renderer)
      refute_receive {:DOWN, ^monitor, :process, ^renderer, _reason}, 50

      RendererServer.cast_snapshot(renderer, snapshot.intent, 103)
      refute_receive {:ack_pipeline, 103, _, _, _}, 50
      RendererServer.frame_status(renderer, {:frame_applied, 2, 102})
      assert_receive {:ack_pipeline, 103, 2, 102, false}, @async_render_timeout
    end

    test "window ref miss keeps the acknowledged generation/base and invalidates only its window" do
      renderer = start_ack_renderer(self(), pipeline: targeted_probe_pipeline(self()))
      state = build_editor_state(:tui, nil)
      snapshot = Input.from_editor_state(state)

      RendererServer.cast_snapshot(renderer, snapshot.intent, 40)
      assert_receive {:targeted_pipeline, 40, 1, 0, true, [1]}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 1, 40})
      assert_receive {:render_done, %RenderReceipt{frame_seq: 40}}, @async_render_timeout

      RendererServer.cast_snapshot(renderer, snapshot.intent, 41)
      assert_receive {:targeted_pipeline, 41, 1, 40, false, []}, @async_render_timeout
      RendererServer.frame_status(renderer, {:window_ref_miss, 1, 41, 40, 1})

      assert_receive {:targeted_pipeline, targeted_retry, 1, 40, false, [1]},
                     @async_render_timeout

      assert targeted_retry > 41
      assert RendererServer.acknowledgement_state(renderer) == {1, 40}
    end
  end

  describe "resident keyframe recovery" do
    test "connection reset materializes every warm resident row then resumes targeted deltas" do
      {renderer, snapshot, buffer, epoch} = start_warm_resident_renderer(130)
      attach_line_fetch_handler()

      :ok = RendererServer.reset_connection(renderer, snapshot.intent, 10)

      assert_receive {:resident_probe, 10, 2, true, 130, nil, fresh_epoch},
                     @async_render_timeout

      assert fresh_epoch > epoch

      assert_receive {:line_fetch, %{lines_fetched: 130}, %{full_residence?: true}}

      RendererServer.frame_status(renderer, {:frame_applied, 2, 10})

      assert_receive {:render_done, %RenderReceipt{frame_seq: 10, keyframe?: true}},
                     @async_render_timeout

      :ok = Minga.Buffer.Process.move_to(buffer, {64, 0})
      :ok = Minga.Buffer.Process.insert_text(buffer, "Z")
      RendererServer.cast_snapshot(renderer, snapshot.intent, 11)

      assert_receive {:resident_probe, 11, 2, false, 1, [{64, 1, 1}], ^fresh_epoch},
                     @async_render_timeout
    end

    test "stale retry composes separated structural edits in current coordinates" do
      gate = start_supervised!({Agent, fn -> :pause_once end})
      pipeline = stale_once_resident_probe_pipeline(self(), gate)
      {renderer, snapshot, buffer, epoch} = start_warm_resident_renderer(300, pipeline)

      :ok = Minga.Buffer.Process.move_to(buffer, {0, 0})
      :ok = Minga.Buffer.Process.insert_text(buffer, "first\n")
      RendererServer.cast_snapshot(renderer, snapshot.intent, 20)

      assert_receive {:resident_probe_paused, 20}, @async_render_timeout
      :ok = Minga.Buffer.Process.move_to(buffer, {100, 0})
      :ok = Minga.Buffer.Process.insert_text(buffer, "second\n")
      send(renderer, :continue_resident_probe)

      assert_receive {:resident_probe, 20, 1, false, 102, [{0, 100, 102}], ^epoch},
                     @async_render_timeout

      RendererServer.frame_status(renderer, {:frame_applied, 1, 20})
      assert_receive {:render_done, %RenderReceipt{frame_seq: 20}}, @async_render_timeout
    end

    test "transaction recovery materializes every warm resident row then resumes targeted deltas" do
      {renderer, snapshot, buffer, epoch} = start_warm_resident_renderer(130)
      attach_line_fetch_handler()

      RendererServer.cast_snapshot(renderer, snapshot.intent, 20)
      assert_receive {:resident_probe, 20, 1, false, 0, [], ^epoch}, @async_render_timeout
      assert_receive {:line_fetch, %{lines_fetched: 24}, %{full_residence?: true}}

      reject_base_sequence_mismatch(renderer, 1, 20, 3)

      assert_receive {:resident_probe, retry_seq, 2, true, 130, nil, fresh_epoch},
                     @async_render_timeout

      assert fresh_epoch > epoch

      assert_receive {:line_fetch, %{lines_fetched: 130}, %{full_residence?: true}}
      assert retry_seq > 20
      RendererServer.frame_status(renderer, {:frame_applied, 2, retry_seq})

      assert_receive {:render_done, %RenderReceipt{frame_seq: ^retry_seq, keyframe?: true}},
                     @async_render_timeout

      :ok = Minga.Buffer.Process.move_to(buffer, {64, 0})
      :ok = Minga.Buffer.Process.insert_text(buffer, "Z")
      RendererServer.cast_snapshot(renderer, snapshot.intent, 30)

      assert_receive {:resident_probe, 30, 2, false, 1, [{64, 1, 1}], ^fresh_epoch},
                     @async_render_timeout
    end
  end

  describe "render_or_async dispatch" do
    test "non-headless render without Renderer.Server fails closed" do
      state = build_editor_state(:tui, nil)
      assert Minga.Test.HeadlessPort.frame_count(state.frontend.port_manager) == 0

      result = MingaEditor.Renderer.render_buffer(state)

      assert result == state
      assert result.render.renderer == nil
      assert Minga.Test.HeadlessPort.frame_count(state.frontend.port_manager) == 0
    end

    test "non-headless backend with renderer dispatches asynchronously" do
      renderer = start_renderer(self(), pipeline: & &1)
      state = build_editor_state(:tui, renderer)

      result = MingaEditor.Renderer.render_or_async(state)

      assert result.render.render_correlation.latest_intent_revision ==
               state.render.render_correlation.latest_intent_revision + 1

      assert %{result | render: state.render} == state

      assert_receive {:render_done, %RenderReceipt{}},
                     @async_render_timeout
    end

    test "traditional launchpad render correlates before a normal async render" do
      renderer = start_ack_renderer(self())
      state = build_editor_state(:tui, renderer)
      launchpad = MingaEditor.State.enter_empty_state(state)
      assert launchpad.workspace.buffers.active == nil

      rendered_launchpad = MingaEditor.Renderer.render_or_async(launchpad)
      assert rendered_launchpad.render.render_correlation.latest_intent_revision == 1

      assert_receive {:ack_pipeline, launchpad_seq, 1, 0, true}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 1, launchpad_seq})

      assert_receive {:render_done,
                      %RenderReceipt{frame_seq: ^launchpad_seq, intent_revision: 1} = receipt},
                     @async_render_timeout

      assert {integrated_launchpad, :applied} =
               MingaEditor.State.integrate_renderer_receipt(rendered_launchpad, receipt)

      normal = %{state | render: integrated_launchpad.render}
      rendered_normal = MingaEditor.Renderer.render_or_async(normal)
      assert rendered_normal.render.render_correlation.latest_intent_revision == 2

      assert_receive {:ack_pipeline, normal_seq, 1, ^launchpad_seq, false},
                     @async_render_timeout

      RendererServer.frame_status(renderer, {:frame_applied, 1, normal_seq})

      assert_receive {:render_done,
                      %RenderReceipt{frame_seq: ^normal_seq, intent_revision: 2} = normal_receipt},
                     @async_render_timeout

      assert {_integrated_normal, :applied} =
               MingaEditor.State.integrate_renderer_receipt(rendered_normal, normal_receipt)
    end

    test "direct non-headless render keeps delta-base advancement behind frontend acknowledgement" do
      renderer = start_ack_renderer(self())
      state = build_editor_state(:tui, renderer)
      intent = Intent.from_editor_state(state)

      RendererServer.cast_snapshot(renderer, intent, 13)
      assert_receive {:ack_pipeline, 13, 1, 0, true}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 1, 13})

      assert_receive {:render_done, %RenderReceipt{frame_seq: 13, keyframe?: true}},
                     @async_render_timeout

      result = MingaEditor.Renderer.render_buffer(state)
      assert result.render.render_correlation.latest_intent_revision == 1

      assert_receive {:ack_pipeline, direct_seq, 1, 13, false}, @async_render_timeout
      assert RendererServer.rendering?(renderer)
      refute_receive {:render_done, %RenderReceipt{frame_seq: ^direct_seq}}, 50

      RendererServer.frame_status(renderer, {:frame_applied, 1, direct_seq})

      assert_receive {:render_done,
                      %RenderReceipt{
                        frame_seq: ^direct_seq,
                        keyframe?: false,
                        intent_revision: 1
                      } = direct_receipt},
                     @async_render_timeout

      assert {integrated, :applied} =
               MingaEditor.State.integrate_renderer_receipt(result, direct_receipt)

      next = MingaEditor.Renderer.render_or_async(integrated)
      assert_receive {:ack_pipeline, next_seq, 1, ^direct_seq, false}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 1, next_seq})

      assert_receive {:render_done,
                      %RenderReceipt{frame_seq: ^next_seq, intent_revision: 2} = next_receipt},
                     @async_render_timeout

      assert {_integrated, :applied} =
               MingaEditor.State.integrate_renderer_receipt(next, next_receipt)

      assert next.render.render_correlation.latest_intent_revision == 2
    end

    test "keyframe handoff survives a superseding intent without forcing another keyframe" do
      renderer = start_ack_renderer(self())
      state = build_editor_state(:tui, renderer)
      correlation = RenderCorrelation.request_keyframe(state.render.render_correlation)
      state = %{state | render: Render.accept_correlation(state.render, correlation)}

      recovered = MingaEditor.Renderer.render_or_async(state)
      refute recovered.render.render_correlation.keyframe_pending?

      assert_receive {:ack_pipeline, first_seq, 2, 0, true}, @async_render_timeout

      superseding = MingaEditor.Renderer.render_or_async(recovered)
      refute superseding.render.render_correlation.keyframe_pending?

      RendererServer.frame_status(renderer, {:frame_applied, 2, first_seq})

      assert_receive {:render_done, %RenderReceipt{frame_seq: ^first_seq, keyframe?: true}},
                     @async_render_timeout

      assert_receive {:ack_pipeline, second_seq, 2, ^first_seq, false}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 2, second_seq})

      assert_receive {:render_done, %RenderReceipt{frame_seq: ^second_seq, keyframe?: false}},
                     @async_render_timeout
    end

    test "consecutive headless renders reuse renderer-process cache and consume targeted deltas" do
      state = build_editor_state(:headless, nil)

      capabilities = %{
        state.frontend.capabilities
        | frontend_type: :native_gui,
          float_support: :native,
          text_rendering: :proportional,
          semantic_ui: true
      }

      state = %{state | frontend: %{state.frontend | capabilities: capabilities}}

      assert Minga.Test.HeadlessPort.frame_count(state.frontend.port_manager) == 0

      result = MingaEditor.Renderer.render_or_async(state)

      assert result.render.layout != nil
      assert Minga.Test.HeadlessPort.frame_count(state.frontend.port_manager) > 0

      editor_window = Map.fetch!(result.workspace.windows.map, result.workspace.windows.active)
      assert %MingaEditor.Window{} = editor_window
      assert %MingaEditor.Window.RenderCache{} = editor_window.render_cache
      refute Map.has_key?(editor_window.render_cache, :retained_rows)

      repeated = MingaEditor.Renderer.render_or_async(result)
      assert repeated.workspace.windows.map == result.workspace.windows.map
      assert repeated.render.renderer == result.render.renderer
      refute Map.has_key?(Map.from_struct(repeated), :caches)

      resident_before = :sys.get_state(repeated.render.renderer).resident_windows[1]

      identity_before =
        MingaEditor.Renderer.WindowCache.line_identity(resident_before.render_cache)

      ids_before = LineIdentity.source_ids(identity_before)
      epoch_before = resident_before.render_cache.content_epoch
      buffer = repeated.workspace.buffers.active
      :ok = Minga.Buffer.move_to(buffer, {0, 0})
      :ok = Minga.Buffer.insert_text(buffer, "Z")

      edited = MingaEditor.Renderer.render_or_async(repeated)
      resident_after = :sys.get_state(edited.render.renderer).resident_windows[1]
      identity_after = MingaEditor.Renderer.WindowCache.line_identity(resident_after.render_cache)

      assert edited.render.renderer == repeated.render.renderer
      assert LineIdentity.source_ids(identity_after) == ids_before
      assert resident_after.render_cache.content_epoch == epoch_before

      observed = :sys.get_state(edited.render.renderer).observed_buffers
      assert ObservedBuffers.recorded_version(observed, buffer) == Minga.Buffer.version(buffer)

      assert resident_after.render_cache.pending_edit_deltas == []
      assert {:ok, []} = Minga.Buffer.consume_edit_deltas(buffer, :renderer)

      confirmed = MingaEditor.Renderer.render_or_async(edited)
      frontend_window = :sys.get_state(confirmed.frontend.port_manager).windows[1]

      assert confirmed.render.renderer == edited.render.renderer
      assert [row] = frontend_window.rows
      assert row.text == "Ztest"
    end

    test "non-headless synchronous shells retain acknowledgement ownership during keyframe reset" do
      renderer = start_ack_renderer(self())
      state = build_sync_shell_state(renderer)
      correlation = RenderCorrelation.request_keyframe(state.render.render_correlation)
      state = %{state | render: Render.accept_correlation(state.render, correlation)}

      result = MingaEditor.Renderer.render_or_async(state)
      refute result.render.render_correlation.keyframe_pending?

      assert_receive {:ack_pipeline, frame_seq, 2, 0, true}, @async_render_timeout

      superseding = MingaEditor.Renderer.render_or_async(result)
      refute superseding.render.render_correlation.keyframe_pending?
      refute_receive {:render_done, _receipt}, 50

      RendererServer.frame_status(renderer, {:frame_applied, 2, frame_seq})

      assert_receive {:render_done, %RenderReceipt{frame_seq: ^frame_seq, keyframe?: true}},
                     @async_render_timeout

      assert_receive {:ack_pipeline, next_seq, 2, ^frame_seq, false}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 2, next_seq})

      assert_receive {:render_done, %RenderReceipt{frame_seq: ^next_seq, keyframe?: false}},
                     @async_render_timeout
    end

    test "shells that opt out of async rendering render synchronously even when a renderer pid is present" do
      renderer = start_renderer(self())
      state = build_sync_shell_state(renderer)

      result = MingaEditor.Renderer.render_or_async(state)

      assert result == state
      refute_receive {:render_done, _writeback}, 50
    end
  end

  defp start_warm_resident_renderer(line_count, pipeline \\ nil) do
    content = Enum.map_join(0..(line_count - 1), "\n", &"line #{&1}")
    state = build_editor_state(:tui, nil, content)
    buffer = state.workspace.buffers.active
    {:ok, false} = Minga.Buffer.Process.set_option(buffer, :wrap, false)

    capabilities = %{
      state.frontend.capabilities
      | frontend_type: :native_gui,
        float_support: :native,
        text_rendering: :proportional,
        semantic_ui: true
    }

    state = %{state | frontend: %{state.frontend | capabilities: capabilities}}
    snapshot = Input.from_editor_state(state)
    renderer = start_ack_renderer(self(), pipeline: pipeline || resident_probe_pipeline(self()))

    RendererServer.cast_snapshot(renderer, snapshot.intent, 1)

    assert_receive {:resident_probe, 1, 1, true, _first_rows, nil, _first_epoch},
                   @async_render_timeout

    RendererServer.frame_status(renderer, {:frame_applied, 1, 1})
    assert_receive {:render_done, %RenderReceipt{frame_seq: 1}}, @async_render_timeout

    RendererServer.cast_snapshot(renderer, snapshot.intent, 2)

    assert_receive {:resident_probe, 2, 1, false, ^line_count, nil, epoch},
                   @async_render_timeout

    RendererServer.frame_status(renderer, {:frame_applied, 1, 2})
    assert_receive {:render_done, %RenderReceipt{frame_seq: 2}}, @async_render_timeout

    RendererServer.cast_snapshot(renderer, snapshot.intent, 3)
    assert_receive {:resident_probe, 3, 1, false, 0, [], ^epoch}, @async_render_timeout
    RendererServer.frame_status(renderer, {:frame_applied, 1, 3})
    assert_receive {:render_done, %RenderReceipt{frame_seq: 3}}, @async_render_timeout

    {renderer, snapshot, buffer, epoch}
  end

  defp stale_once_resident_probe_pipeline(parent, gate) do
    delegate = resident_probe_pipeline(parent)

    fn input ->
      maybe_pause_resident_probe(input, parent, gate)
      delegate.(input)
    end
  end

  defp maybe_pause_resident_probe(%{frame_seq: 20} = input, parent, gate) do
    gate
    |> Agent.get_and_update(fn
      :pause_once -> {:pause, :open}
      :open -> {:continue, :open}
    end)
    |> handle_resident_probe_gate(input, parent)
  end

  defp maybe_pause_resident_probe(_input, _parent, _gate), do: :ok

  defp handle_resident_probe_gate(:continue, _input, _parent), do: :ok

  defp handle_resident_probe_gate(:pause, input, parent) do
    send(parent, {:resident_probe_paused, input.frame_seq})

    receive do
      :continue_resident_probe -> :ok
    end

    raise MingaEditor.Renderer.StaleBufferError,
      buffer: input.workspace.buffers.active,
      expected_version: 1
  end

  defp resident_probe_pipeline(parent) do
    fn input ->
      input = RenderPipeline.compute_layout(input)
      layout = Layout.get(input)

      {prefetched, input} =
        MingaEditor.RenderPipeline.BufferPrefetch.prefetch_scrolls(input, layout)

      {scrolls, input} =
        MingaEditor.RenderPipeline.Scroll.scroll_windows(input, layout, prefetched)

      {contents, _cursor, output} = Content.build_content(input, scrolls)
      model = contents |> List.first() |> Map.fetch!(:models) |> List.first()

      keyframe? =
        input.intent.frame.force_keyframe? or input.caches.last_acknowledged_frame_seq == 0

      splices =
        if model.row_delta do
          Enum.map(model.row_delta.splices, fn splice ->
            {splice.start_index, splice.delete_count, length(splice.insert_rows)}
          end)
        end

      send(parent, {
        :resident_probe,
        input.frame_seq,
        input.caches.recovery_generation,
        keyframe?,
        length(model.rows),
        splices,
        model.content_epoch
      })

      %{
        output
        | caches: %{
            output.caches
            | last_emitted_frame_seq: input.frame_seq,
              last_frame_keyframe?: keyframe?
          }
      }
    end
  end

  defp start_renderer(editor_pid, opts \\ []) do
    opts =
      [name: nil, editor_pid: editor_pid]
      |> Keyword.merge(opts)
      |> Keyword.put_new_lazy(:generation_reserver, &generation_reserver/0)

    start_supervised!({RendererServer, opts})
  end

  defp start_ack_renderer(editor_pid, opts \\ []) do
    pipeline = Keyword.get(opts, :pipeline, acknowledgement_probe_pipeline(editor_pid))
    start_renderer(editor_pid, Keyword.merge(opts, pipeline: pipeline, require_ack?: true))
  end

  defp generation_reserver do
    counter = :atomics.new(1, [])
    fn -> :atomics.add_get(counter, 1, 1) end
  end

  defp acknowledgement_probe_pipeline(parent) do
    fn input ->
      keyframe? =
        input.intent.frame.force_keyframe? or input.caches.last_acknowledged_frame_seq == 0

      send(parent, {
        :ack_pipeline,
        input.frame_seq,
        input.caches.recovery_generation,
        input.caches.last_acknowledged_frame_seq,
        keyframe?
      })

      %{
        input
        | caches: %{
            input.caches
            | last_emitted_frame_seq: input.frame_seq,
              last_frame_keyframe?: keyframe?
          }
      }
    end
  end

  defp pending_window_delta_probe_pipeline(parent) do
    fn input ->
      send(parent, {:pending_window_deltas, input.frame_seq, [1, 2]})
      input |> put_pending_window_deltas() |> put_emitted_frame_seq()
    end
  end

  defp first_generation_pending_delta_pipeline(parent) do
    acknowledge = acknowledgement_probe_pipeline(parent)

    fn input ->
      output = acknowledge.(input)

      if input.caches.recovery_generation == 1,
        do: put_pending_window_deltas(output),
        else: output
    end
  end

  defp put_pending_window_deltas(input) do
    %GUICaches{} = adapter_gui_caches = input.caches.adapter_gui_caches

    adapter_gui_caches = %GUICaches{
      adapter_gui_caches
      | last_window_content_fps: %{1 => 101, 2 => 202},
        pending_window_delta_ids: MapSet.new([1, 2])
    }

    %{input | caches: %{input.caches | adapter_gui_caches: adapter_gui_caches}}
  end

  defp put_emitted_frame_seq(input),
    do: %{input | caches: %{input.caches | last_emitted_frame_seq: input.frame_seq}}

  defp adaptation_probe_pipeline(parent) do
    fn input ->
      keyframe? =
        input.intent.frame.force_keyframe? or input.caches.last_acknowledged_frame_seq == 0

      send(parent, {
        :adaptation_pipeline,
        input.frame_seq,
        input.caches.recovery_generation,
        input.caches.last_acknowledged_frame_seq,
        keyframe?,
        input.intent.frame.capabilities.semantic_ui
      })

      %{
        input
        | caches: %{
            input.caches
            | last_emitted_frame_seq: input.frame_seq,
              last_frame_keyframe?: keyframe?
          }
      }
    end
  end

  defp lineage_probe_pipeline(parent) do
    fn input -> update_lineage(input, parent) end
  end

  defp failing_lineage_probe_pipeline(parent, failure_mode) do
    fn input ->
      output = update_lineage(input, parent)

      should_fail? =
        Agent.get_and_update(failure_mode, fn
          :fail_once -> {true, :succeed}
          :succeed -> {false, :succeed}
        end)

      maybe_fail_lineage_pipeline(output, should_fail?)
    end
  end

  defp maybe_fail_lineage_pipeline(_output, true),
    do: raise("deliberate lineage pipeline failure")

  defp maybe_fail_lineage_pipeline(output, false), do: output

  defp update_lineage(input, parent) do
    {window_id, window} = Enum.at(input.windows.map, 0)
    input_identity = Window.line_identity(window)
    input_ids = if input_identity, do: LineIdentity.source_ids(input_identity), else: nil
    input_sequence = window.render_cache.applied_change_sequence

    expected_version = Window.expected_buffer_version(window)
    {:buffer, buffer} = window.content
    {:ok, snapshot} = Minga.Buffer.render_lines(buffer, expected_version, 0, 0)
    updated_window = Window.sync_line_identity(window, snapshot)
    output_identity = Window.line_identity(updated_window)

    send(parent, {
      :lineage_probe,
      input.frame_seq,
      input_ids,
      input_sequence,
      LineIdentity.source_ids(output_identity),
      updated_window.render_cache.applied_change_sequence
    })

    windows = input.windows
    updated_windows = %{windows | map: Map.put(windows.map, window_id, updated_window)}
    %{input | windows: updated_windows}
  end

  defp targeted_probe_pipeline(parent) do
    fn input ->
      reset_windows =
        input.windows.map
        |> Enum.filter(fn {_id, window} -> window.render_cache.reset_pending end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      keyframe? =
        input.intent.frame.force_keyframe? or input.caches.last_acknowledged_frame_seq == 0

      send(parent, {
        :targeted_pipeline,
        input.frame_seq,
        input.caches.recovery_generation,
        input.caches.last_acknowledged_frame_seq,
        keyframe?,
        reset_windows
      })

      windows =
        Map.new(input.windows.map, fn {id, window} ->
          {id, %{window | render_cache: %{window.render_cache | reset_pending: false}}}
        end)

      %{
        input
        | windows: %{input.windows | map: windows},
          caches: %{
            input.caches
            | last_emitted_frame_seq: input.frame_seq,
              last_frame_keyframe?: keyframe?
          }
      }
    end
  end

  defp emit_commit_frame(input) do
    # The HeadlessPort fires :frame_ready on commit_frame (#2219), so a minimal
    # pipeline stub only needs to send a frame terminator.
    MingaEditor.Frontend.send_commands(input.intent.frame.port_manager, [
      MingaEditor.Frontend.Protocol.encode_commit_frame(input.frame_seq || 0)
    ])

    input
  end

  defp cache_probe_pipeline(parent) do
    fn input ->
      send(parent, {:pipeline_input, input.frame_seq, input.caches.last_emitted_frame_seq})
      %{input | caches: %{input.caches | last_emitted_frame_seq: input.frame_seq}}
    end
  end

  defp attach_line_fetch_handler do
    handler_id = {__MODULE__, :line_fetch, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:minga, :render, :line_fetch],
        fn _name, measurements, metadata, _config ->
          send(parent, {:line_fetch, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_coalesce_handler do
    handler_id = {__MODULE__, :coalesced, make_ref()}

    handler = fn name, measurements, metadata, parent ->
      send(parent, {:tel, name, measurements, metadata})
    end

    :ok = :telemetry.attach(handler_id, [:minga, :render, :coalesced], handler, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp park_in_flight(renderer) do
    :sys.replace_state(renderer, fn state ->
      RendererState.schedule_frame(state, FrameAttempt.new(stub_intent(), 0, 0), make_ref())
    end)
  end

  defp elem_from_coalesce(state, attempt) do
    {:coalesced, coalesced, _dropped} = RendererState.coalesce_frame(state, attempt)
    coalesced
  end

  defp renderer_busy?(renderer, attempts \\ 8)
  defp renderer_busy?(renderer, 0), do: RendererServer.rendering?(renderer)

  defp renderer_busy?(renderer, attempts) do
    if RendererServer.rendering?(renderer) do
      renderer_busy?(renderer, attempts - 1)
    else
      false
    end
  end

  defp pending_lease_window_ids(renderer) do
    {:awaiting_ack, lease, _successor} = :sys.get_state(renderer).frame_credit
    lease.output.caches.adapter_gui_caches.pending_window_delta_ids
  end

  defp connected_ack_pipeline(manager) do
    fn input ->
      generation = input.caches.recovery_generation
      frame_seq = input.frame_seq
      base_frame_seq = input.caches.last_acknowledged_frame_seq

      :accepted =
        Manager.send_render_commands(
          manager,
          connected_frame_commands(frame_seq, base_frame_seq, generation)
        )

      %{
        input
        | caches: %{
            input.caches
            | last_emitted_frame_seq: frame_seq,
              last_frame_keyframe?: base_frame_seq == 0
          }
      }
    end
  end

  defp connected_frame_commands(frame_seq, base_frame_seq, generation) do
    [
      Protocol.encode_begin_frame(frame_seq, base_frame_seq, generation),
      Protocol.encode_commit_frame(frame_seq)
    ]
  end

  defp frame_header(
         <<_opcode, frame_seq::32, base_frame_seq::32, generation::32, _rest::binary>>
       ),
       do: {frame_seq, base_frame_seq, generation}

  defp ready_packet(width, height) do
    capabilities = <<0, 2, 1, 0, 0, 0, 1, 1, 64 * 1024 * 1024::32, 0::32, 0::32>>
    version = Minga.Protocol.Opcodes.protocol_version()
    <<0x03, width::16, height::16, 2, 20, capabilities::binary, version::16>>
  end

  defp unique_process_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

  defp reject_base_sequence_mismatch(renderer, generation, frame_seq, last_applied) do
    RendererServer.frame_status(
      renderer,
      {:frame_rejected, generation, frame_seq, last_applied, :base_sequence_mismatch,
       :retryable_recovery}
    )
  end

  defp stub_intent, do: stub_snapshot().intent

  defp intent_of(%Input{} = input), do: input.intent

  defp put_frame(%Input{} = input, frame) do
    %{input | intent: %{input.intent | frame: frame}}
  end

  defp stub_snapshot do
    intent = manual_intent()

    windows = %Windows{
      tree: intent.window_layout.tree,
      map: manual_render_windows(intent),
      active: intent.window_layout.active,
      next_id: intent.window_layout.next_id
    }

    Input.from_intent(
      intent,
      windows,
      %Caches{},
      MingaEditor.UI.FontRegistry.new(),
      intent.frame.message_store
    )
  end

  defp manual_intent do
    window = manual_window_intent()

    %Intent{
      frame: manual_frame_intent(),
      workspace: manual_workspace_intent(),
      windows: %{1 => window},
      window_layout: %{tree: MingaEditor.WindowTree.new(1), active: 1, next_id: 2},
      buffer_versions: %{},
      revision: 0
    }
  end

  defp manual_render_windows(%Intent{} = intent) do
    Map.new(intent.windows, fn {id, %WindowIntent{} = window} ->
      {id, Window.materialize(id, window, MingaEditor.Renderer.WindowCache.reset())}
    end)
  end

  defp manual_window_intent do
    %WindowIntent{
      content: {:empty, :semantic},
      viewport: MingaEditor.Viewport.new(24, 80),
      cursor: {0, 0},
      fold_map: %MingaEditor.FoldMap{folds: []},
      fold_ranges: [],
      popup_meta: nil,
      scroll_velocity: %MingaEditor.Window.ScrollVelocity{},
      scroll_detach_cursor: nil,
      scroll_echo_top: nil,
      authoritative_scroll_seq: 0
    }
  end

  defp manual_workspace_intent do
    %WorkspaceIntent{
      buffers: %MingaEditor.State.Buffers{},
      file_tree: %MingaEditor.State.FileTree{},
      agent_ui: MingaEditor.Agent.UIState.new(),
      editing: MingaEditor.VimState.new(),
      document_highlights: nil,
      cmd_hover_link: nil,
      mouse: %MingaEditor.State.Mouse{},
      search: %MingaEditor.State.Search{},
      keymap_scope: :editor,
      launchpad: nil
    }
  end

  defp manual_frame_intent do
    shell_entry = MingaEditor.Shell.Registry.get(:traditional)

    shell_runtime = ShellRuntime.new(shell_entry, %MingaEditor.Shell.Traditional.State{})

    %FrameIntent{
      port_manager: nil,
      theme: MingaEditor.UI.Theme.get!(MingaEditor.UI.Theme.default()),
      capabilities: %MingaEditor.Frontend.Capabilities{},
      shell_id: ShellRuntime.id(shell_runtime),
      shell: ShellRuntime.module(shell_runtime),
      shell_identity: ShellRuntime.identity(shell_runtime),
      shell_state: ShellRuntime.state(shell_runtime),
      message_store: MingaEditor.UI.Panel.MessageStore.new(),
      notifications: [],
      sidebar_registry: MingaEditor.Extension.Sidebar.default_table(),
      face_override_registries: %{},
      editing_model: :vim,
      backend: :tui,
      layout: nil,
      focus_tree: nil,
      diff_views: %{},
      git_syncing: false,
      status_bar_data: nil,
      highlighting: %MingaEditor.State.Highlighting{},
      semantic_tokens: %{},
      terminal_viewport: MingaEditor.Viewport.new(24, 80),
      last_input_seq: 0,
      force_keyframe?: false,
      line_spacing: 1.0,
      cursor_animate: nil,
      gui_config_state: nil,
      presentation_target: nil
    }
  end

  defp build_sync_shell_state(renderer_pid) do
    :tui
    |> build_editor_state(renderer_pid)
    |> MingaEditor.Shell.Workflow.switch(:fake)
  end

  defp build_editor_state(backend, renderer_pid, content \\ "test") do
    buf =
      start_supervised!(Supervisor.child_spec({Minga.Buffer, content: content}, id: make_ref()))

    workspace = %MingaEditor.Session.State{
      buffers: %MingaEditor.State.Buffers{
        active: buf,
        list: [buf],
        active_index: 0
      },
      editing: MingaEditor.VimState.new(),
      windows: %MingaEditor.State.Windows{
        tree: MingaEditor.WindowTree.new(1),
        map: %{1 => MingaEditor.Window.new(1, buf, 24, 80)},
        active: 1,
        next_id: 2
      },
      keymap_scope: :editor
    }

    port =
      start_supervised!(
        Supervisor.child_spec({Minga.Test.HeadlessPort, width: 80, height: 24}, id: make_ref())
      )

    %MingaEditor.State{
      frontend: %MingaEditor.State.Frontend{backend: backend, port_manager: port},
      workspace: workspace,
      render: %MingaEditor.State.Render{renderer: renderer_pid},
      shell_runtime:
        MingaEditor.Shell.Runtime.new(
          MingaEditor.Shell.Registry.get(:traditional),
          %MingaEditor.Shell.Traditional.State{}
        )
    }
  end
end
