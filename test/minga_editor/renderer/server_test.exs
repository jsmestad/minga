defmodule MingaEditor.Renderer.ServerTest do
  @moduledoc """
  Focused tests for the standalone Renderer GenServer.

  Pipeline details are covered in render-pipeline tests. This file checks the server-level contract: coalescing telemetry, crash tolerance, writeback, and async-vs-sync dispatch.
  """

  # Registers a fake shell in the global shell registry for async-render opt-out coverage.
  use ExUnit.Case, async: false

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.Viewport

  # Async renderer writeback can lag a bit under CI load, keep this local to the renderer assertions.
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

    RendererServer.cast_snapshot(renderer, stub_snapshot(), 1)
    RendererServer.cast_snapshot(renderer, stub_snapshot(), 2)
    RendererServer.cast_snapshot(renderer, stub_snapshot(), 3)

    assert_receive {:tel, [:minga, :render, :coalesced], %{count: 1},
                    %{dropped_seq: 1, new_seq: 2}}

    assert_receive {:tel, [:minga, :render, :coalesced], %{count: 1},
                    %{dropped_seq: 2, new_seq: 3}}
  end

  test "pipeline crashes drop frames without killing the server" do
    renderer = start_renderer(self(), pipeline: fn _input -> raise "boom" end)

    RendererServer.cast_snapshot(renderer, stub_snapshot(), 42)

    refute renderer_busy?(renderer)
    assert Process.alive?(renderer)
  end

  test "successful async render sends writeback and emits a frame" do
    renderer = start_renderer(self(), pipeline: &emit_commit_frame/1)
    state = build_editor_state(:tui, nil)
    snapshot = Input.from_editor_state(state)
    frame_ref = Minga.Test.HeadlessPort.prepare_await(state.port_manager)

    RendererServer.cast_snapshot(renderer, snapshot, 123)

    assert {:ok, _screen} =
             Minga.Test.HeadlessPort.collect_frame(frame_ref, @async_render_timeout)

    assert_receive {:render_done, %{frame_seq: 123, caches: %MingaEditor.Renderer.Caches{}}},
                   @async_render_timeout

    refute renderer_busy?(renderer)
  end

  test "pending snapshots inherit the latest emitted caches before rendering" do
    parent = self()
    renderer = start_renderer(parent, pipeline: cache_probe_pipeline(parent))
    initial_caches = %Caches{last_emitted_frame_seq: 10}
    in_flight = %{stub_snapshot() | caches: initial_caches}
    pending = %{stub_snapshot() | caches: initial_caches}

    :sys.replace_state(renderer, fn state ->
      %{state | rendering?: true, in_flight: {in_flight, 11, 0}, pending: {pending, 12, 0}}
    end)

    send(renderer, :do_render)

    assert_receive {:pipeline_input, 11, 10}, @async_render_timeout
    assert_receive {:pipeline_input, 12, 11}, @async_render_timeout

    assert_receive {:render_done, %{frame_seq: 11, caches: %Caches{last_emitted_frame_seq: 11}}},
                   @async_render_timeout

    assert_receive {:render_done, %{frame_seq: 12, caches: %Caches{last_emitted_frame_seq: 12}}},
                   @async_render_timeout
  end

  describe "frame acknowledgement credit" do
    test "apply advances the base while duplicate, out-of-order, stale, and wrong-generation statuses do not" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_snapshot(), 10)
      assert_receive {:ack_pipeline, 10, 1, 0, true}, @async_render_timeout

      RendererServer.cast_snapshot(renderer, stub_snapshot(), 11)
      RendererServer.cast_snapshot(renderer, stub_snapshot(), 12)

      RendererServer.frame_status(renderer, {:frame_applied, 2, 10})
      RendererServer.frame_status(renderer, {:frame_applied, 1, 9})
      RendererServer.frame_status(renderer, {:frame_rejected, 1, 10, 99, :base_sequence_mismatch})
      assert RendererServer.acknowledgement_state(renderer) == {1, 0}
      refute_receive {:ack_pipeline, _, _, _, _}, 50

      RendererServer.frame_status(renderer, {:frame_applied, 1, 10})
      assert_receive {:render_done, %{frame_seq: 10, keyframe?: true}}, @async_render_timeout
      assert_receive {:ack_pipeline, 12, 1, 10, false}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {1, 10}

      RendererServer.frame_status(renderer, {:frame_applied, 1, 10})
      RendererServer.frame_status(renderer, {:frame_rejected, 0, 12, 10, :base_sequence_mismatch})
      assert RendererServer.acknowledgement_state(renderer) == {1, 10}
      refute_receive {:render_done, %{frame_seq: 12}}, 50
    end

    test "acknowledgement timeout retries the latest pending frame as a fresh-generation keyframe" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_snapshot(), 10)
      assert_receive {:ack_pipeline, 10, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_snapshot(), 11)

      send(renderer, {:frame_ack_timeout, 1, 10})

      assert_receive {:ack_pipeline, 11, 2, 0, true}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
      refute_receive {:render_done, %{frame_seq: 10}}, 50
    end

    test "late acknowledgement from a timed-out generation cannot release current credit" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_snapshot(), 20)
      assert_receive {:ack_pipeline, 20, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_snapshot(), 21)
      send(renderer, {:frame_ack_timeout, 1, 20})
      assert_receive {:ack_pipeline, 21, 2, 0, true}, @async_render_timeout

      RendererServer.frame_status(renderer, {:frame_applied, 1, 20})
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
      refute_receive {:render_done, %{frame_seq: 20}}, 50

      RendererServer.frame_status(renderer, {:frame_applied, 2, 21})
      assert_receive {:render_done, %{frame_seq: 21}}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {2, 21}
    end

    test "normal acknowledgement makes its queued timeout message harmless" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_snapshot(), 30)
      assert_receive {:ack_pipeline, 30, 1, 0, true}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 1, 30})
      assert_receive {:render_done, %{frame_seq: 30}}, @async_render_timeout

      send(renderer, {:frame_ack_timeout, 1, 30})
      refute RendererServer.rendering?(renderer)
      assert RendererServer.acknowledgement_state(renderer) == {1, 30}
      refute_receive {:ack_pipeline, _, _, _, _}, 50

      RendererServer.cast_snapshot(renderer, stub_snapshot(), 31)
      assert_receive {:ack_pipeline, 31, 1, 30, false}, @async_render_timeout
    end

    test "rejected frame N renders only latest pending N+1 as a fresh-generation keyframe" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_snapshot(), 20)
      assert_receive {:ack_pipeline, 20, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_snapshot(), 21)

      RendererServer.frame_status(renderer, {:frame_rejected, 1, 20, 0, :base_sequence_mismatch})
      assert_receive {:ack_pipeline, 21, 2, 0, true}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
      refute_receive {:ack_pipeline, _, 3, _, _}, 50
      refute_receive {:render_done, %{frame_seq: 20}}, 50
    end

    test "manual retry returns the credit and advances recovery generation every time" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_snapshot(), 30)
      assert_receive {:ack_pipeline, 30, 1, 0, true}, @async_render_timeout

      RendererServer.request_recovery(renderer)
      assert_receive {:ack_pipeline, first_retry, 2, 0, true}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}

      RendererServer.request_recovery(renderer)
      assert_receive {:ack_pipeline, second_retry, 3, 0, true}, @async_render_timeout
      assert second_retry > first_retry
      assert RendererServer.acknowledgement_state(renderer) == {3, 0}
    end

    test "connection reset abandons outstanding credit and resumes from a base-zero keyframe" do
      renderer = start_ack_renderer(self())

      RendererServer.cast_snapshot(renderer, stub_snapshot(), 50)
      assert_receive {:ack_pipeline, 50, 1, 0, true}, @async_render_timeout
      RendererServer.cast_snapshot(renderer, stub_snapshot(), 51)

      :ok = RendererServer.reset_connection(renderer, stub_snapshot(), 60)
      assert_receive {:ack_pipeline, 60, 2, 0, true}, @async_render_timeout
      refute_receive {:ack_pipeline, 51, _, _, _}, 50

      RendererServer.frame_status(renderer, {:frame_applied, 1, 50})
      assert RendererServer.acknowledgement_state(renderer) == {2, 0}
      refute_receive {:render_done, %{frame_seq: 50}}, 50

      RendererServer.frame_status(renderer, {:frame_applied, 2, 60})
      assert_receive {:render_done, %{frame_seq: 60}}, @async_render_timeout

      RendererServer.cast_snapshot(renderer, stub_snapshot(), 61)
      assert_receive {:ack_pipeline, 61, 2, 60, false}, @async_render_timeout
      assert RendererServer.acknowledgement_state(renderer) == {2, 60}
    end

    test "window ref miss keeps the acknowledged generation/base and invalidates only its window" do
      renderer = start_ack_renderer(self(), pipeline: targeted_probe_pipeline(self()))
      state = build_editor_state(:tui, nil)
      snapshot = Input.from_editor_state(state)

      RendererServer.cast_snapshot(renderer, snapshot, 40)
      assert_receive {:targeted_pipeline, 40, 1, 0, true, [1]}, @async_render_timeout
      RendererServer.frame_status(renderer, {:frame_applied, 1, 40})
      assert_receive {:render_done, %{frame_seq: 40}}, @async_render_timeout

      clean_snapshot =
        snapshot
        |> Map.update!(:caches, fn caches ->
          %{caches | last_emitted_frame_seq: 40, last_acknowledged_frame_seq: 40}
        end)
        |> update_in(
          [
            Access.key!(:workspace),
            Access.key!(:windows),
            Access.key!(:map),
            1,
            Access.key!(:render_cache)
          ],
          fn cache ->
            %{cache | dirty_lines: %{}, reset_pending: false}
          end
        )

      RendererServer.cast_snapshot(renderer, clean_snapshot, 41)
      assert_receive {:targeted_pipeline, 41, 1, 40, false, []}, @async_render_timeout
      RendererServer.frame_status(renderer, {:window_ref_miss, 1, 41, 40, 1})

      assert_receive {:targeted_pipeline, targeted_retry, 1, 40, false, [1]},
                     @async_render_timeout

      assert targeted_retry > 41
      assert RendererServer.acknowledgement_state(renderer) == {1, 40}
    end
  end

  describe "render_or_async dispatch" do
    test "non-headless backend with renderer dispatches asynchronously" do
      renderer = start_renderer(self(), pipeline: & &1)
      state = build_editor_state(:tui, renderer)

      result = MingaEditor.Renderer.render_or_async(state)

      assert result == state

      assert_receive {:render_done, %{caches: %MingaEditor.Renderer.Caches{}}},
                     @async_render_timeout
    end

    test "nil renderer falls back to synchronous rendering" do
      state = build_editor_state(:tui, nil)
      assert Minga.Test.HeadlessPort.frame_count(state.port_manager) == 0

      result = MingaEditor.Renderer.render_or_async(state)

      assert result.layout != nil
      assert Minga.Test.HeadlessPort.frame_count(state.port_manager) > 0
    end

    test "shells that opt out of async rendering render synchronously even when a renderer pid is present" do
      renderer = start_renderer(self())
      state = build_sync_shell_state(renderer)

      result = MingaEditor.Renderer.render_or_async(state)

      assert result == state
      refute_receive {:render_done, _writeback}, 50
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
      %{state | rendering?: true, in_flight: {stub_snapshot(), 0, 0}}
    end)
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
    state = build_editor_state(:tui, renderer_pid)

    %{
      state
      | shell_id: :fake,
        shell: MingaEditor.Test.FakeShell,
        shell_identity: MingaEditor.Shell.Identity.new(MingaEditor.Shell.Registry.get(:fake)),
        shell_state: MingaEditor.Test.FakeShell.init([])
    }
  end

  defp build_editor_state(backend, renderer_pid) do
    buf = start_supervised!({Minga.Buffer, content: "test"})

    workspace = %MingaEditor.Session.State{
      buffers: %MingaEditor.State.Buffers{
        active: buf,
        list: [buf],
        active_index: 0
      },
      viewport: Viewport.new(24, 80),
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
      backend: backend,
      port_manager: port,
      workspace: workspace,
      renderer: renderer_pid,
      shell_id: :traditional,
      shell: MingaEditor.Shell.Traditional,
      shell_state: %MingaEditor.Shell.Traditional.State{}
    }
  end
end
