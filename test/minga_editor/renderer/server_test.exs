defmodule MingaEditor.Renderer.ServerTest do
  @moduledoc """
  Focused tests for the standalone Renderer GenServer.

  Pipeline details are covered in render-pipeline tests. This file checks the server-level contract: coalescing telemetry, crash tolerance, writeback, and async-vs-sync dispatch.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.Shell.Board
  alias MingaEditor.Shell.Board.State, as: BoardState
  alias MingaEditor.Viewport

  # Async renderer writeback can lag a bit under CI load, keep this local to the renderer assertions.
  @async_render_timeout 5_000

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
    renderer = start_renderer(self(), pipeline: &emit_batch_end/1)
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

    test "Board grid renders synchronously even when a renderer pid is present" do
      renderer = start_renderer(self())
      state = build_board_grid_state(renderer)
      frame_ref = Minga.Test.HeadlessPort.prepare_await(state.port_manager)

      result = MingaEditor.Renderer.render_or_async(state)
      assert {:ok, screen} = Minga.Test.HeadlessPort.collect_frame(frame_ref)

      rows = screen_rows(screen)
      assert result == state
      assert Enum.any?(rows, &String.contains?(&1, "The Board"))
      assert Enum.any?(rows, &String.contains?(&1, "Fix split renderer"))
      refute_receive {:render_done, _writeback}, 50
    end
  end

  defp start_renderer(editor_pid, opts \\ []) do
    opts = Keyword.merge([name: nil, editor_pid: editor_pid], opts)
    start_supervised!({RendererServer, opts})
  end

  defp emit_batch_end(input) do
    MingaEditor.Frontend.send_commands(input.port_manager, [
      MingaEditor.Frontend.Protocol.encode_batch_end()
    ])

    input
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
      }
    }
  end

  defp screen_rows(%{grid: grid}) do
    Enum.map(grid, fn row -> Enum.map_join(row, & &1.char) end)
  end

  defp build_board_grid_state(renderer_pid) do
    state = build_editor_state(:tui, renderer_pid)
    {board, _card} = BoardState.create_card(BoardState.new(), task: "Fix split renderer")
    %{state | shell_id: :board, shell: Board, shell_state: board}
  end

  defp build_editor_state(backend, renderer_pid) do
    buf = start_supervised!({Minga.Buffer, content: "test"})

    workspace = %MingaEditor.Session.State{
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
      shell_id: :traditional,
      shell: MingaEditor.Shell.Traditional,
      shell_state: %MingaEditor.Shell.Traditional.State{}
    }
  end
end
