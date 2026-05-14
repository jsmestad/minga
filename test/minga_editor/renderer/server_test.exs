defmodule MingaEditor.Renderer.ServerTest do
  @moduledoc """
  Unit tests for the standalone Renderer GenServer.

  Tests the snapshot/coalescing/writeback contract directly without
  booting the editor. These tests start a process per-test for isolation.

  Tests that would require running the actual `RenderPipeline.run/1`
  are out of scope for unit tests; pipeline behavior is covered by
  the existing render pipeline test suite. These tests focus on the
  state-machine contract: idle → rendering, coalescing, telemetry.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.Shell.Board
  alias MingaEditor.Shell.Board.State, as: BoardState
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.Viewport

  describe "snapshot coalescing (in-flight → pending replacement)" do
    setup do
      pid = start_renderer(self())

      # Park the server in "rendering" so subsequent casts go to pending.
      :sys.replace_state(pid, fn s ->
        %{s | rendering?: true, in_flight: {stub_snapshot(), 0, 0}}
      end)

      %{pid: pid}
    end

    test "first pending snapshot is stored without a coalesce event", %{pid: pid} do
      attach_coalesce_handler()

      RendererServer.cast_snapshot(pid, stub_snapshot(), 1)
      :sys.get_state(pid)
      state = :sys.get_state(pid)

      assert {_, 1, _} = state.pending
      refute_receive {:tel, [:minga, :render, :coalesced], _, _}, 50
    end

    test "subsequent pending snapshot replaces the prior one with a telemetry event", %{pid: pid} do
      attach_coalesce_handler()

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
    end
  end

  describe "do_render rescue (fault tolerance)" do
    test "pipeline crash drops the frame and advances to pending without killing the server" do
      pid = start_renderer(self())

      # Cast a snapshot that will crash the pipeline (stub_snapshot lacks
      # required fields for RenderPipeline.run/1). The server should rescue
      # and remain alive rather than crashing the supervision tree.
      RendererServer.cast_snapshot(pid, stub_snapshot(), 42)

      state = drain_renderer_until_idle(pid)
      refute state.rendering?
      assert state.in_flight == nil
    end

    test "pipeline crash still drains pending snapshot into next attempt" do
      pid = start_renderer(self())

      :sys.replace_state(pid, fn state ->
        %{
          state
          | rendering?: true,
            in_flight: {stub_snapshot(), 1, 0},
            pending: {stub_snapshot(), 2, 0}
        }
      end)

      send(pid, :do_render)

      # Both will crash, but the server drains pending after each rescue.
      state = drain_renderer_until_idle(pid)
      refute state.rendering?
      assert state.pending == nil
      assert state.in_flight == nil
    end
  end

  describe "successful async render" do
    test "renderer owns font registry outside editor state" do
      renderer = start_renderer(self())
      state = build_editor_state(:tui, nil)
      snapshot = Input.from_editor_state(state)

      {_id, registry, true} = FontRegistry.get_or_register(FontRegistry.new(), "Fira Code")

      :sys.replace_state(renderer, fn server_state ->
        %{server_state | font_registry: registry}
      end)

      RendererServer.cast_snapshot(renderer, snapshot, 124)

      assert_receive {:render_done, %{frame_seq: 124}}
      server_state = drain_renderer_until_idle(renderer)
      assert FontRegistry.lookup(server_state.font_registry, "Fira Code") == 1
      refute Map.has_key?(Map.from_struct(state), :font_registry)
    end

    test "sends render_done writeback and emits a frame" do
      renderer = start_renderer(self())
      state = build_editor_state(:tui, nil)
      snapshot = Input.from_editor_state(state)
      frame_ref = Minga.Test.HeadlessPort.prepare_await(state.port_manager)

      RendererServer.cast_snapshot(renderer, snapshot, 123)

      assert_receive {:render_done,
                      %{
                        frame_seq: 123,
                        caches: %MingaEditor.Renderer.Caches{},
                        layout: %MingaEditor.Layout{},
                        shell_state: %MingaEditor.Shell.Traditional.State{},
                        windows: %MingaEditor.State.Windows{}
                      }},
                     1_000

      assert {:ok, _screen} = Minga.Test.HeadlessPort.collect_frame(frame_ref)
      state = drain_renderer_until_idle(renderer)
      refute state.rendering?
    end
  end

  describe "render_or_async dispatch" do
    test "non-nil renderer pid dispatches async (returns state unchanged)" do
      renderer = start_renderer(self())
      state = build_editor_state(:tui, renderer)

      :sys.replace_state(renderer, fn server_state ->
        %{server_state | rendering?: true, in_flight: {stub_snapshot(), 0, 0}}
      end)

      result = MingaEditor.Renderer.render_or_async(state)
      server_state = :sys.get_state(renderer)
      assert {_, seq, _} = server_state.pending

      assert result == state
      assert is_integer(seq) and seq > 0
    end

    test "nil renderer with non-headless backend falls back to sync render" do
      state = build_editor_state(:tui, nil)
      assert Minga.Test.HeadlessPort.frame_count(state.port_manager) == 0

      result = MingaEditor.Renderer.render_or_async(state)

      assert result.layout != nil
      assert Minga.Test.HeadlessPort.frame_count(state.port_manager) > 0
    end

    test "headless backend renders synchronously with no renderer pid" do
      state = build_editor_state(:headless, nil)
      assert Minga.Test.HeadlessPort.frame_count(state.port_manager) == 0

      result = MingaEditor.Renderer.render_or_async(state)

      assert result.layout != nil
      assert Minga.Test.HeadlessPort.frame_count(state.port_manager) > 0
    end

    test "headless backend renders synchronously even when renderer pid is present" do
      renderer = start_renderer(self())
      state = build_editor_state(:headless, renderer)
      assert Minga.Test.HeadlessPort.frame_count(state.port_manager) == 0

      result = MingaEditor.Renderer.render_or_async(state)
      server_state = :sys.get_state(renderer)

      assert result.layout != nil
      assert Minga.Test.HeadlessPort.frame_count(state.port_manager) > 0
      refute server_state.rendering?
      assert server_state.pending == nil
      assert server_state.in_flight == nil
      refute_receive {:render_done, _writeback}, 50
    end

    test "Board grid renders synchronously even when renderer pid is present" do
      renderer = start_renderer(self())
      state = build_board_grid_state(renderer)

      :sys.replace_state(renderer, fn server_state ->
        %{server_state | rendering?: true, in_flight: {stub_snapshot(), 0, 0}, pending: nil}
      end)

      frame_ref = Minga.Test.HeadlessPort.prepare_await(state.port_manager)
      result = MingaEditor.Renderer.render_or_async(state)
      assert {:ok, screen} = Minga.Test.HeadlessPort.collect_frame(frame_ref)

      rows = screen_rows(screen)
      assert Enum.any?(rows, &String.contains?(&1, "The Board"))
      assert Enum.any?(rows, &String.contains?(&1, "Fix split renderer"))

      server_state = :sys.get_state(renderer)
      assert result == state
      assert server_state.pending == nil
      assert {_, 0, 0} = server_state.in_flight
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp start_renderer(editor_pid) do
    start_supervised!({RendererServer, name: nil, editor_pid: editor_pid})
  end

  defp attach_coalesce_handler do
    handler_id = {__MODULE__, :coalesced, make_ref()}

    handler = fn name, measurements, metadata, parent ->
      send(parent, {:tel, name, measurements, metadata})
    end

    :ok = :telemetry.attach(handler_id, [:minga, :render, :coalesced], handler, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp drain_renderer_until_idle(pid, attempts \\ 8)

  defp drain_renderer_until_idle(pid, 0), do: :sys.get_state(pid)

  defp drain_renderer_until_idle(pid, attempts) do
    state = :sys.get_state(pid)

    if state.rendering? do
      drain_renderer_until_idle(pid, attempts - 1)
    else
      state
    end
  end

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

  defp screen_rows(%{grid: grid}) do
    Enum.map(grid, fn row -> Enum.map_join(row, & &1.char) end)
  end

  defp build_board_grid_state(renderer_pid) do
    state = build_editor_state(:tui, renderer_pid)
    {board, _card} = BoardState.create_card(BoardState.new(), task: "Fix split renderer")
    %{state | shell: Board, shell_state: board}
  end

  defp build_editor_state(backend, renderer_pid) do
    buf = start_supervised!({Minga.Buffer, content: "test"})

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

    port = start_supervised!({Minga.Test.HeadlessPort, width: 80, height: 24})

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
