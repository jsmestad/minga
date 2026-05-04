defmodule MingaEditor.EditorTest do
  @moduledoc """
  Integration smoke tests for the Editor GenServer.

  Pure-function and Layer-1 contracts that used to live here have been
  moved closer to the modules they exercise:

    * Mode FSM dispatch shape & Esc-to-rest invariants
      → `test/minga/mode/properties_test.exs`
    * Read-only buffer guard for `i` / `R`
      → `test/minga_editor/commands/insert_entry_test.exs`
    * Commands no-op when no active buffer
      → `test/minga_editor/commands/no_buffer_test.exs`
    * Per-key Mode.process/3 dispatch shape
      → `test/minga/mode/normal_test.exs` (already covered)

  This file keeps only tests that exercise contracts the GenServer
  itself owns: port roundtrip, file open, viewport propagation through
  the editor process, and stale-timer message handling.
  """
  use Minga.Test.EditingModelCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  defp start_editor(content \\ "hello\nworld\nfoo") do
    {:ok, buffer} = BufferServer.start_link(content: content)

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

  describe "build_initial_state/1" do
    test "returns an EditorState in :normal mode" do
      {:ok, buffer} = BufferServer.start_link(content: "hi")

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
  end

  describe "render/1" do
    test "render cast doesn't crash with a buffer" do
      {editor, _buffer} = start_editor()
      MingaEditor.render(editor)
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end

    test "render cast doesn't crash without a buffer" do
      {:ok, editor} =
        MingaEditor.start_link(
          name: :"editor_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: nil,
          width: 40,
          height: 10,
          editing_model: :vim
        )

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

  describe "whichkey timeout" do
    test "real-timer fires end-to-end and is ignored when ref is stale" do
      {editor, _buffer} = start_editor()
      before_whichkey = :sys.get_state(editor).shell_state.whichkey

      # Real timer using Process.send_after with a ref that does NOT match
      # the editor's stored timer (nil by default). The handler's stale-ref
      # branch must return state unchanged — popup stays hidden.
      timer_ref = Process.send_after(editor, {:whichkey_timeout, make_ref()}, 0)

      # Wait until the timer has actually fired (read_timer returns false
      # once it's been delivered), then sync via :sys.get_state.
      _ = await_timer_fired(timer_ref)
      after_whichkey = :sys.get_state(editor).shell_state.whichkey

      assert after_whichkey.show == before_whichkey.show
      assert after_whichkey.timer == before_whichkey.timer
    end

    test "stale ref handler is a pure no-op (called directly with a fabricated ref)" do
      {editor, _buffer} = start_editor()
      state = :sys.get_state(editor)

      # `whichkey.timer` defaults to nil; any fresh ref differs from nil
      # so the handler hits the stale-ref branch.
      assert {:noreply, ^state} =
               MingaEditor.handle_info({:whichkey_timeout, make_ref()}, state)

      assert EditorState.whichkey(state).timer == nil
    end
  end

  # Polls Process.read_timer/1 until the timer has been delivered. Bounded
  # by 50 iterations × 1ms to keep the test from hanging if something goes
  # wrong with the timer wheel.
  defp await_timer_fired(ref, attempts \\ 50)
  defp await_timer_fired(_ref, 0), do: :timeout

  defp await_timer_fired(ref, attempts) do
    case Process.read_timer(ref) do
      false -> :ok
      _ms_left -> await_timer_fired(ref, attempts - 1)
    end
  end
end
