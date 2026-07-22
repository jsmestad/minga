defmodule MingaEditor.Renderer.ServerTest do
  @moduledoc """
  Focused tests for the standalone Renderer GenServer.

  Pipeline details are covered in render-pipeline tests. This file checks the server-level contract: coalescing telemetry, crash tolerance, writeback, and async-vs-sync dispatch.
  """

  # Registers a fake shell in the global shell registry for async-render opt-out coverage.
  use ExUnit.Case, async: false

  alias Minga.RenderModel.Window.LineIdentity
  alias MingaEditor.Frontend.ResourcePolicy
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.Renderer.ObservedBuffers
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.State.Render
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.Viewport
  alias MingaEditor.Renderer.RenderWindow, as: Window

  @async_render_timeout 5_000

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

    RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 123)

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
    in_flight = stub_snapshot() |> Map.put(:caches, initial_caches) |> Intent.from_input()
    pending = stub_snapshot() |> Map.put(:caches, initial_caches) |> Intent.from_input()

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

    RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 70)
    assert_receive {:lineage_probe, 70, nil, 0, [0, 1, 2], 0}, @async_render_timeout

    :ok = Minga.Buffer.Process.move_to(buffer, {0, 0})
    :ok = Minga.Buffer.Process.insert_text(buffer, "new\n")
    RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 71)
    RendererServer.frame_status(renderer, {:frame_applied, 1, 70})

    assert_receive {:lineage_probe, 71, [3, 0, 1, 2], 1, [3, 0, 1, 2], 1},
                   @async_render_timeout
  end

  test "rejection rehydrates lineage in a fresh content epoch" do
    state = build_editor_state(:tui, nil, "a\nb")
    snapshot = Input.from_editor_state(state)
    buffer = state.workspace.buffers.active
    renderer = start_ack_renderer(self(), pipeline: lineage_probe_pipeline(self()))

    RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 80)
    assert_receive {:lineage_probe, 80, nil, 0, [0, 1], 0}, @async_render_timeout

    :ok = Minga.Buffer.Process.move_to(buffer, {0, 0})
    :ok = Minga.Buffer.Process.insert_text(buffer, "new\n")
    RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 81)
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

    RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 89)
    assert_receive {:lineage_probe, 89, nil, 0, [0, 1], 0}, @async_render_timeout
    assert_receive {:render_done, %RenderReceipt{frame_seq: 89}}, @async_render_timeout

    :ok = Minga.Buffer.Process.move_to(buffer, {0, 0})
    :ok = Minga.Buffer.Process.insert_text(buffer, "new\n")
    Agent.update(failure_mode, fn _ -> :fail_once end)

    token = make_ref()

    :sys.replace_state(renderer, fn renderer_state ->
      renderer_state
      |> RendererState.schedule_frame(FrameAttempt.new(Intent.from_input(snapshot), 90, 0), token)
      |> elem_from_coalesce(FrameAttempt.new(Intent.from_input(snapshot), 91, 0))
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

    RendererServer.cast_snapshot(renderer, Intent.from_input(stale_editor_snapshot), 12)

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

    RendererServer.cast_snapshot(renderer, Intent.from_input(reset_snapshot), 12)

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
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 10)
      assert_receive {:ack_pipeline, 10, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_intent(), 11)

      send(renderer, {:frame_ack_timeout, 1, 10})

      assert_receive {:ack_pipeline, 11, 2, 0, true}, @async_render_timeout
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
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 20)
      assert_receive {:ack_pipeline, 20, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_intent(), 21)

      RendererServer.frame_status(
        renderer,
        {:frame_rejected, 1, 20, 0, :base_sequence_mismatch, :retryable_recovery}
      )

      assert_receive {:ack_pipeline, 21, 2, 0, true}, @async_render_timeout
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
      intent = Intent.from_input(snapshot)

      RendererServer.cast_snapshot(renderer, intent, 20)
      assert_receive {:ack_pipeline, 20, 1, 0, true}, @async_render_timeout

      RendererServer.frame_status(
        renderer,
        {:frame_rejected, 1, 20, 0, :resource_policy, :terminal_frontend_failure}
      )

      refute RendererServer.rendering?(renderer)
      RendererServer.cast_snapshot(renderer, intent, 21)
      refute_receive {:ack_pipeline, 21, _, _, _}, 50

      changed = %{
        snapshot
        | capabilities: %{snapshot.capabilities | semantic_ui: true}
      }

      RendererServer.cast_snapshot(renderer, Intent.from_input(changed), 22)
      assert_receive {:ack_pipeline, 22, 1, 0, true}, @async_render_timeout
      assert RendererServer.terminal_failure(renderer) == nil
    end

    test "adapted retry consumes only matching evidence and renders the changed intent" do
      renderer = start_ack_renderer(self(), pipeline: adaptation_probe_pipeline(self()))

      snapshot = stub_snapshot()
      policy = ResourcePolicy.new(1, 64 * 1_048_576, 0, 0)
      snapshot = %{snapshot | capabilities: %{snapshot.capabilities | resource_policy: policy}}
      rejected_intent = Intent.from_input(snapshot)

      adapted_snapshot = %{snapshot | capabilities: %{snapshot.capabilities | semantic_ui: true}}
      adapted_intent = Intent.from_input(adapted_snapshot)

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

    test "manual retry returns the credit and advances recovery generation every time" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_intent(), 30)
      assert_receive {:ack_pipeline, 30, 1, 0, true}, @async_render_timeout

      RendererServer.request_recovery(renderer)
      assert_receive {:ack_pipeline, first_retry, 2, 0, true}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}

      RendererServer.request_recovery(renderer)
      assert_receive {:ack_pipeline, second_retry, 3, 0, true}, @async_render_timeout
      assert second_retry > first_retry
      assert RendererServer.acknowledgement_state(renderer) == {3, 0}
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

      RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 100)
      assert_receive {:ack_pipeline, 100, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 101)

      :ok = :sys.suspend(renderer)
      RendererServer.frame_status(renderer, {:frame_applied, 1, 100})

      call_ref = make_ref()
      intent = MingaEditor.RenderPipeline.Intent.from_input(snapshot)

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

      RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 103)
      refute_receive {:ack_pipeline, 103, _, _, _}, 50
      RendererServer.frame_status(renderer, {:frame_applied, 2, 102})
      assert_receive {:ack_pipeline, 103, 2, 102, false}, @async_render_timeout
    end

    test "window ref miss keeps the acknowledged generation/base and invalidates only its window" do
      renderer = start_ack_renderer(self(), pipeline: targeted_probe_pipeline(self()))
      state = build_editor_state(:tui, nil)
      snapshot = Input.from_editor_state(state)

      RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 40)
      assert_receive {:targeted_pipeline, 40, 1, 0, true, [1]}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 1, 40})
      assert_receive {:render_done, %RenderReceipt{frame_seq: 40}}, @async_render_timeout

      clean_snapshot =
        Map.update!(snapshot, :caches, fn caches ->
          %{caches | last_emitted_frame_seq: 40, last_acknowledged_frame_seq: 40}
        end)

      RendererServer.cast_snapshot(renderer, Intent.from_input(clean_snapshot), 41)
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

      :ok = RendererServer.reset_connection(renderer, Intent.from_input(snapshot), 10)

      assert_receive {:resident_probe, 10, 2, true, 130, nil, fresh_epoch},
                     @async_render_timeout

      assert fresh_epoch > epoch

      assert_receive {:line_fetch, %{lines_fetched: 130}, %{full_residence?: true}}

      RendererServer.frame_status(renderer, {:frame_applied, 2, 10})

      assert_receive {:render_done, %RenderReceipt{frame_seq: 10, keyframe?: true}},
                     @async_render_timeout

      :ok = Minga.Buffer.Process.move_to(buffer, {64, 0})
      :ok = Minga.Buffer.Process.insert_text(buffer, "Z")
      RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 11)

      assert_receive {:resident_probe, 11, 2, false, 1, [{64, 1, 1}], ^fresh_epoch},
                     @async_render_timeout
    end

    test "stale retry composes separated structural edits in current coordinates" do
      gate = start_supervised!({Agent, fn -> :pause_once end})
      pipeline = stale_once_resident_probe_pipeline(self(), gate)
      {renderer, snapshot, buffer, epoch} = start_warm_resident_renderer(300, pipeline)

      :ok = Minga.Buffer.Process.move_to(buffer, {0, 0})
      :ok = Minga.Buffer.Process.insert_text(buffer, "first\n")
      RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 20)

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

      RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 20)
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
      RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 30)

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

    RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 1)

    assert_receive {:resident_probe, 1, 1, true, _first_rows, nil, _first_epoch},
                   @async_render_timeout

    RendererServer.frame_status(renderer, {:frame_applied, 1, 1})
    assert_receive {:render_done, %RenderReceipt{frame_seq: 1}}, @async_render_timeout

    RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 2)

    assert_receive {:resident_probe, 2, 1, false, ^line_count, nil, epoch},
                   @async_render_timeout

    RendererServer.frame_status(renderer, {:frame_applied, 1, 2})
    assert_receive {:render_done, %RenderReceipt{frame_seq: 2}}, @async_render_timeout

    RendererServer.cast_snapshot(renderer, Intent.from_input(snapshot), 3)
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
      keyframe? = input.force_keyframe? or input.caches.last_acknowledged_frame_seq == 0

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
    opts = Keyword.merge([name: nil, editor_pid: editor_pid], opts)
    start_supervised!({RendererServer, opts})
  end

  defp start_ack_renderer(editor_pid, opts \\ []) do
    pipeline = Keyword.get(opts, :pipeline, acknowledgement_probe_pipeline(editor_pid))
    start_renderer(editor_pid, Keyword.merge(opts, pipeline: pipeline, require_ack?: true))
  end

  defp acknowledgement_probe_pipeline(parent) do
    fn input ->
      keyframe? = input.force_keyframe? or input.caches.last_acknowledged_frame_seq == 0

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

  defp adaptation_probe_pipeline(parent) do
    fn input ->
      keyframe? = input.force_keyframe? or input.caches.last_acknowledged_frame_seq == 0

      send(parent, {
        :adaptation_pipeline,
        input.frame_seq,
        input.caches.recovery_generation,
        input.caches.last_acknowledged_frame_seq,
        keyframe?,
        input.capabilities.semantic_ui
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
    {window_id, window} = Enum.at(input.workspace.windows.map, 0)
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

    windows = input.workspace.windows
    workspace = input.workspace
    updated_windows = %{windows | map: Map.put(windows.map, window_id, updated_window)}
    %{input | workspace: %{workspace | windows: updated_windows}}
  end

  defp targeted_probe_pipeline(parent) do
    fn input ->
      reset_windows =
        input.workspace.windows.map
        |> Enum.filter(fn {_id, window} -> window.render_cache.reset_pending end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      keyframe? = input.force_keyframe? or input.caches.last_acknowledged_frame_seq == 0

      send(parent, {
        :targeted_pipeline,
        input.frame_seq,
        input.caches.recovery_generation,
        input.caches.last_acknowledged_frame_seq,
        keyframe?,
        reset_windows
      })

      windows =
        Map.new(input.workspace.windows.map, fn {id, window} ->
          {id, %{window | render_cache: %{window.render_cache | reset_pending: false}}}
        end)

      %{
        input
        | workspace: %{
            input.workspace
            | windows: %{input.workspace.windows | map: windows}
          },
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
    MingaEditor.Frontend.send_commands(input.port_manager, [
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

  defp reject_base_sequence_mismatch(renderer, generation, frame_seq, last_applied) do
    RendererServer.frame_status(
      renderer,
      {:frame_rejected, generation, frame_seq, last_applied, :base_sequence_mismatch,
       :retryable_recovery}
    )
  end

  defp stub_intent, do: Intent.from_input(stub_snapshot())

  defp stub_snapshot do
    %Input{
      port_manager: self(),
      theme: MingaEditor.UI.Theme.get!(:doom_one),
      capabilities: %MingaEditor.Frontend.Capabilities{},
      shell_id: :traditional,
      shell: MingaEditor.Shell.Traditional,
      workspace: %{
        windows: %MingaEditor.State.Windows{},
        viewport: Viewport.new(24, 80)
      },
      message_store: MessageStore.new()
    }
  end

  defp build_sync_shell_state(renderer_pid) do
    :tui
    |> build_editor_state(renderer_pid)
    |> MingaEditor.Shell.Workflow.switch(:fake)
  end

  defp build_editor_state(backend, renderer_pid, content \\ "test") do
    buf = start_supervised!({Minga.Buffer, content: content})

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

    port = start_supervised!({Minga.Test.HeadlessPort, width: 80, height: 24})

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
