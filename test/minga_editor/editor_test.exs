defmodule MingaEditor.EditorTest do
  @moduledoc """
  Integration smoke tests for the Editor GenServer: contracts the
  GenServer itself owns (port roundtrip, file open, viewport
  propagation, stale-timer dispatch, status_msg surfacing).
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  defp start_editor(content \\ "hello\nworld\nfoo") do
    {:ok, buffer} = BufferProcess.start_link(content: content)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10,
        editing_model: :vim
      )

    {editor, buffer}
  end

  defp start_editor_no_buffer do
    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: nil,
        width: 40,
        height: 10,
        editing_model: :vim
      )

    editor
  end

  describe "build_initial_state/1" do
    test "returns an EditorState in :normal mode with the buffer wired up" do
      {:ok, buffer} = BufferProcess.start_link(content: "hi")

      state =
        Startup.build_initial_state(
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      assert state.workspace.editing.mode == :normal
      assert Minga.Editing.mode(state) == :normal
      assert state.workspace.buffers.active == buffer
    end

    test "creates a default [new 1] buffer when none is provided" do
      state =
        Startup.build_initial_state(
          port_manager: nil,
          buffer: nil,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      assert state.workspace.editing.mode == :normal
      # Render pipeline / command dispatch / input routing all assume
      # buffers.active is a pid, so Startup synthesises one when caller
      # passes nil.
      assert is_pid(state.workspace.buffers.active)
    end
  end

  describe "render/1" do
    test "render cast doesn't crash with a buffer" do
      {editor, _buffer} = start_editor()
      MingaEditor.render(editor)
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end

    test "render cast doesn't crash without a buffer" do
      editor = start_editor_no_buffer()
      MingaEditor.render(editor)
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end
  end

  describe "open_file/2" do
    @tag :tmp_dir
    test "opens a file and renders", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test_open.txt")
      File.write!(path, "opened file content")

      {:ok, editor} =
        MingaEditor.start_link(
          name: :"editor_open_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: nil,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      assert :ok = MingaEditor.open_file(editor, path)
    end
  end

  describe "resize" do
    test "port-driven resize updates the workspace viewport" do
      {editor, _buffer} = start_editor()
      send(editor, {:minga_input, {:resize, 120, 40}})
      state = :sys.get_state(editor)

      assert %Viewport{rows: 40, cols: 120} = state.workspace.viewport
    end
  end

  describe "ready" do
    test "ready event seeds the workspace viewport columns" do
      {editor, _buffer} = start_editor()
      send(editor, {:minga_input, {:ready, 100, 30}})
      state = :sys.get_state(editor)

      assert state.workspace.viewport.cols == 100
    end
  end

  describe "unknown handle_info messages" do
    test "stray messages are dropped without crashing" do
      {editor, _buffer} = start_editor()
      ref = Process.monitor(editor)
      send(editor, :some_random_message)
      send(editor, {:unexpected, :tuple})
      _ = :sys.get_state(editor)

      refute_received {:DOWN, ^ref, :process, _, _}
    end
  end

  describe "read-only buffer through the GenServer" do
    # Layer-1 KeyDispatch behaviour is covered in
    # test/minga_editor/commands/insert_entry_test.exs. This smoke test
    # exists to catch regressions where Editor.handle_info swallows or
    # rewrites the status_msg surfaced by KeyDispatch.
    test "pressing i on a read-only buffer surfaces status_msg in shell_state" do
      {:ok, buffer} = BufferProcess.start_link(content: "read only", read_only: true)

      {:ok, editor} =
        MingaEditor.start_link(
          name: :"editor_ro_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      send(editor, {:minga_input, {:key_press, ?i, 0}})
      state = :sys.get_state(editor)

      assert state.workspace.editing.mode == :normal
      assert state.shell_state.status_msg == "Buffer is read-only"
    end
  end

  describe "whichkey timeout" do
    test "real-timer fires end-to-end and is ignored when ref is stale" do
      {editor, _buffer} = start_editor()
      before_whichkey = :sys.get_state(editor).shell_state.whichkey

      # Ref does not match the editor's stored timer (nil by default), so the
      # handler must hit its stale-ref branch and leave the popup hidden.
      timer_ref = Process.send_after(editor, {:whichkey_timeout, make_ref()}, 0)

      assert :ok = await_timer_fired(timer_ref)
      after_whichkey = :sys.get_state(editor).shell_state.whichkey

      assert after_whichkey.show == before_whichkey.show
      assert after_whichkey.timer == before_whichkey.timer
    end

    test "stale ref handler is a pure no-op (called directly with a fabricated ref)" do
      {editor, _buffer} = start_editor()
      state = :sys.get_state(editor)
      assert EditorState.whichkey(state).timer == nil

      # Any fresh ref differs from the nil-default timer, so the handler hits
      # the stale-ref branch and returns state unchanged (pinned match below).
      assert {:noreply, ^state} =
               MingaEditor.handle_info({:whichkey_timeout, make_ref()}, state)
    end
  end

  # Polls Process.read_timer/1 until the timer has been delivered. Bounded by
  # 50 iterations of 1ms sleeps so the test fails loudly via :timeout instead
  # of hanging if the timer wheel ever stalls.
  defp await_timer_fired(ref, attempts \\ 50)
  defp await_timer_fired(_ref, 0), do: :timeout

  defp await_timer_fired(ref, attempts) do
    case Process.read_timer(ref) do
      false ->
        :ok

      _ms_left ->
        Process.sleep(1)
        await_timer_fired(ref, attempts - 1)
    end
  end
end
