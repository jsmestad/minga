defmodule MingaEditor.Renderer.ServerTest do
  @moduledoc """
  Unit tests for the standalone Renderer GenServer.

  Tests the snapshot/coalescing/writeback contract directly without
  booting the editor. The server is normally started under
  `MingaEditor.Supervisor` only when the `:split_renderer` flag is on;
  these tests start a process per-test for isolation.

  Tests that would require running the actual `RenderPipeline.run/1`
  are out of scope for unit tests — pipeline behavior is covered by
  the existing render pipeline test suite. These tests focus on the
  state-machine contract: idle → rendering, coalescing, telemetry.
  """

  use ExUnit.Case, async: false

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.Viewport

  describe "enabled?/0" do
    test "returns false when the application env flag is unset" do
      Application.delete_env(:minga, :split_renderer)
      refute RendererServer.enabled?()
    end

    test "returns true when the flag is exactly true" do
      Application.put_env(:minga, :split_renderer, true)
      assert RendererServer.enabled?()
      Application.delete_env(:minga, :split_renderer)
    end

    test "returns false when the flag is anything other than true" do
      Application.put_env(:minga, :split_renderer, :maybe)
      refute RendererServer.enabled?()
      Application.delete_env(:minga, :split_renderer)
    end
  end

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

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Builds a syntactically valid Input. These tests inspect the server's
  # state machine, not pipeline output, so the snapshot's contents only
  # need to satisfy the struct's @enforce_keys.
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
end
