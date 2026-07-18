defmodule MingaEditor.Commands.BufferManagementKillTest do
  @moduledoc "Direct contracts for ordinary and forced buffer destruction."

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer
  alias Minga.Config.Options
  alias Minga.Frontend.WaitRequestCompletion
  alias Minga.Frontend.WaitRequests
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Startup
  alias MingaEditor.State.Launchpad

  setup_all do
    {:ok, tracker} = WaitRequests.start_link()
    on_exit(fn -> GenServer.stop(tracker, :normal) end)
  end

  setup %{tmp_dir: tmp}, do: %{options: start_supervised!({Options, name: nil}), tmp: tmp}

  test "ordinary kill refuses a dirty buffer without completing its wait request", ctx do
    {buffer, path} = file_buffer(ctx.tmp, "dirty-refused", ctx.options)
    state = initial_state(buffer, ctx.options, ctx.tmp)
    tab_id = state.shell_runtime.state.tab_bar.active_id
    :ok = Buffer.insert_text(buffer, " changed")
    content = Buffer.content(buffer)
    request_id = request_id()
    :ok = WaitRequests.register(buffer, path, request_id, self())
    monitor = Process.monitor(buffer)
    state = BufferManagement.execute(state, :kill_buffer)

    assert NoticeWorkflow.message(state) ==
             "Buffer has unsaved changes. Use SPC b X to force kill."

    assert state.workspace.buffers.active == buffer and state.workspace.buffers.list == [buffer]
    assert state.shell_runtime.state.tab_bar.active_id == tab_id
    assert Buffer.content(buffer) == content
    assert Buffer.dirty?(buffer)
    refute_received %WaitRequestCompletion{request_id: ^request_id}
    refute_received {:DOWN, ^monitor, :process, ^buffer, _reason}
  end

  test "ordinary kill destroys a clean buffer and accepts its wait request", ctx do
    {buffer, path} = file_buffer(ctx.tmp, "clean", ctx.options)
    state = initial_state(buffer, ctx.options, ctx.tmp)
    request_id = request_id()
    :ok = WaitRequests.register(buffer, path, request_id, self())
    monitor = Process.monitor(buffer)
    state = BufferManagement.execute(state, :kill_buffer)
    assert_receive %WaitRequestCompletion{request_id: ^request_id, outcome: :accepted}
    assert_receive {:DOWN, ^monitor, :process, ^buffer, :normal}
    assert state.workspace.buffers.active == nil and state.workspace.buffers.list == []
    assert %Launchpad{} = state.workspace.launchpad
  end

  test "force kill destroys a dirty buffer and cancels its wait request", ctx do
    {buffer, path} = file_buffer(ctx.tmp, "force-dirty", ctx.options)
    state = initial_state(buffer, ctx.options, ctx.tmp)
    :ok = Buffer.insert_text(buffer, " changed")
    request_id = request_id()
    :ok = WaitRequests.register(buffer, path, request_id, self())
    monitor = Process.monitor(buffer)

    state = BufferManagement.execute(state, :force_kill_buffer)

    assert_receive %WaitRequestCompletion{
      request_id: ^request_id,
      outcome: {:cancelled, "closed with unsaved changes"}
    }

    assert_receive {:DOWN, ^monitor, :process, ^buffer, :normal}
    assert state.workspace.buffers.list == [] and match?(%Launchpad{}, state.workspace.launchpad)
  end

  test "ordinary and force kills clear persistent buffers without stopping them", ctx do
    for {command, name} <- [
          {:kill_buffer, "persistent-ordinary"},
          {:force_kill_buffer, "persistent-force"}
        ] do
      {buffer, _path} = file_buffer(ctx.tmp, name, ctx.options, persistent: true)
      state = initial_state(buffer, ctx.options, ctx.tmp)
      :ok = Buffer.insert_text(buffer, " changed")
      monitor = Process.monitor(buffer)

      state = BufferManagement.execute(state, command)

      assert NoticeWorkflow.message(state) == "Buffer is persistent — content cleared"
      assert state.workspace.buffers.active == buffer and state.workspace.buffers.list == [buffer]
      assert Buffer.content(buffer) == ""
      assert Buffer.dirty?(buffer)
      refute_received {:DOWN, ^monitor, :process, ^buffer, _reason}
    end
  end

  test "ordinary kill retires an already-exited buffer", ctx do
    {buffer, _path} = file_buffer(ctx.tmp, "already-exited", ctx.options)
    state = initial_state(buffer, ctx.options, ctx.tmp)
    monitor = Process.monitor(buffer)
    :ok = GenServer.stop(buffer, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^buffer, :normal}
    state = BufferManagement.execute(state, :kill_buffer)

    assert state.workspace.buffers.active == nil and state.workspace.buffers.list == []
    assert %Launchpad{} = state.workspace.launchpad

    refute NoticeWorkflow.message(state) ==
             "Buffer has unsaved changes. Use SPC b X to force kill."
  end

  defp file_buffer(tmp, name, options, extra \\ []) do
    path = Path.join(tmp, "#{name}.txt")
    File.write!(path, "original")

    buffer_opts = Keyword.merge([file_path: path, options_server: options], extra)
    buffer = start_supervised!({Buffer, buffer_opts}, id: make_ref())
    {buffer, path}
  end

  defp initial_state(buffer, options, tmp) do
    Startup.build_initial_state(
      port_manager: nil,
      options_server: options,
      buffer: buffer,
      width: 60,
      height: 20,
      editing_model: :vim,
      session_dir: Path.join(tmp, "empty-sessions")
    )
  end

  defp request_id, do: "kill-test-#{System.unique_integer([:positive])}"
end
