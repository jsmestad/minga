defmodule MingaEditor.Renderer.ServerTest do
  @moduledoc """
  Unit tests for the standalone Renderer GenServer.

  Tests the snapshot/coalescing/writeback contract directly without
  booting the editor. These tests start a process per-test for isolation.

  Tests that would require running the actual `RenderPipeline.run/1`
  are out of scope for unit tests — pipeline behavior is covered by
  the existing render pipeline test suite. These tests focus on the
  state-machine contract: idle → rendering, coalescing, telemetry.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.Viewport

  describe "init/1 + start_link/1" do
    test "starts with no pending or in-flight snapshot" do
      {:ok, pid} = RendererServer.start_link(name: nil, editor_pid: self())
      state = :sys.get_state(pid)

      assert state.editor_pid == self()
      refute state.rendering?
      assert state.pending == nil
      assert state.in_flight == nil

      GenServer.stop(pid)
    end
  end

  describe "snapshot coalescing (in-flight → pending replacement)" do
    setup do
      {:ok, pid} = RendererServer.start_link(name: nil, editor_pid: self())

      # Park the server in "rendering" so subsequent casts go to pending.
      :sys.replace_state(pid, fn s ->
        %{s | rendering?: true, in_flight: {stub_snapshot(), 0, 0}}
      end)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      %{pid: pid}
    end

    test "first pending snapshot is stored without a coalesce event", %{pid: pid} do
      handler = fn name, m, meta, parent -> send(parent, {:tel, name, m, meta}) end
      :telemetry.attach("test-coalesce-first", [:minga, :render, :coalesced], handler, self())

      RendererServer.cast_snapshot(pid, stub_snapshot(), 1)
      :sys.get_state(pid)
      state = :sys.get_state(pid)

      assert {_, 1, _} = state.pending
      refute_receive {:tel, [:minga, :render, :coalesced], _, _}, 50

      :telemetry.detach("test-coalesce-first")
    end

    test "subsequent pending snapshot replaces the prior one with a telemetry event", %{pid: pid} do
      handler = fn name, m, meta, parent -> send(parent, {:tel, name, m, meta}) end
      :telemetry.attach("test-coalesce-replace", [:minga, :render, :coalesced], handler, self())

      RendererServer.cast_snapshot(pid, stub_snapshot(), 1)
      :sys.get_state(pid)

      RendererServer.cast_snapshot(pid, stub_snapshot(), 2)
      :sys.get_state(pid)

      RendererServer.cast_snapshot(pid, stub_snapshot(), 3)
      :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert {_, 3, _} = state.pending
      assert {_, 0, _} = state.in_flight

      assert_receive {:tel, [:minga, :render, :coalesced], %{count: 1},
                      %{dropped_seq: 1, new_seq: 2}}

      assert_receive {:tel, [:minga, :render, :coalesced], %{count: 1},
                      %{dropped_seq: 2, new_seq: 3}}

      :telemetry.detach("test-coalesce-replace")
    end
  end

  describe "do_render rescue (fault tolerance)" do
    test "pipeline crash drops the frame and advances to pending without killing the server" do
      {:ok, pid} = RendererServer.start_link(name: nil, editor_pid: self())

      # Cast a snapshot that will crash the pipeline (stub_snapshot lacks
      # required fields for RenderPipeline.run/1). The server should rescue
      # and remain alive rather than crashing the supervision tree.
      RendererServer.cast_snapshot(pid, stub_snapshot(), 42)

      # Give the server time to process :do_render and rescue.
      Process.sleep(50)

      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      refute state.rendering?
      assert state.in_flight == nil

      GenServer.stop(pid)
    end

    test "pipeline crash still drains pending snapshot into next attempt" do
      {:ok, pid} = RendererServer.start_link(name: nil, editor_pid: self())

      # First cast enters rendering. Second cast goes to pending.
      RendererServer.cast_snapshot(pid, stub_snapshot(), 1)
      :sys.get_state(pid)
      RendererServer.cast_snapshot(pid, stub_snapshot(), 2)
      :sys.get_state(pid)

      # Both will crash, but the server drains pending after each rescue.
      Process.sleep(100)

      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      refute state.rendering?
      assert state.pending == nil
      assert state.in_flight == nil

      GenServer.stop(pid)
    end
  end

  describe "render_or_async dispatch" do
    test "non-nil renderer pid dispatches async (returns state unchanged)" do
      {:ok, renderer} = RendererServer.start_link(name: nil, editor_pid: self())
      state = build_editor_state(:tui, renderer)

      result = MingaEditor.Renderer.render_or_async(state)

      assert result == state

      GenServer.stop(renderer)
    end

    test "nil renderer with non-headless backend falls back to sync render" do
      state = build_editor_state(:tui, nil)
      result = MingaEditor.Renderer.render_or_async(state)

      # Sync path updates caches (state is mutated by the pipeline).
      assert result != state
    end

    test "headless backend renders synchronously regardless of renderer pid" do
      state = build_editor_state(:headless, nil)
      result = MingaEditor.Renderer.render_or_async(state)

      assert result != state
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp stub_snapshot do
    %Input{
      port_manager: self(),
      theme: MingaEditor.UI.Theme.get!(:doom_one),
      capabilities: %MingaEditor.Frontend.Capabilities{},
      shell: MingaEditor.Shell.Traditional,
      workspace: %{
        windows: %MingaEditor.State.Windows{},
        viewport: Viewport.new(24, 80)
      }
    }
  end

  defp build_editor_state(backend, renderer_pid) do
    {:ok, buf} = Minga.Buffer.start_link(content: "test")

    workspace = %MingaEditor.Workspace.State{
      buffers: %MingaEditor.State.Buffers{
        active: buf,
        list: [buf],
        active_index: 0,
        messages: buf
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

    {:ok, port} = Minga.Test.HeadlessPort.start_link(width: 80, height: 24)

    %MingaEditor.State{
      backend: backend,
      port_manager: port,
      workspace: workspace,
      renderer: renderer_pid,
      shell: MingaEditor.Shell.Traditional,
      shell_state: %MingaEditor.Shell.Traditional.State{}
    }
  end
end
