defmodule MingaEditor.EnsureBufferEditorTest do
  @moduledoc false

  use Minga.Test.EditorCase, async: true

  @moduletag :tmp_dir

  describe "ensure_buffer_for_path/2 with a running editor" do
    test "registers a different file in the background without crashing", %{tmp_dir: dir} do
      path = Path.join(dir, "tracked.ex")
      other_path = Path.join(dir, "other.ex")
      File.write!(path, "tracked")
      File.write!(other_path, "other")
      ctx = start_editor("tracked", file_path: path)
      editor = ctx.editor
      original = active_buffer(ctx)
      monitor = Process.monitor(editor)

      assert {:ok, new_buf} = MingaEditor.ensure_buffer_for_path(other_path, editor)
      on_exit(fn -> if Process.alive?(new_buf), do: GenServer.stop(new_buf) end)

      state = editor_state(ctx)
      assert state.workspace.buffers.active == original
      assert state.workspace.buffers.list == [original, new_buf]
      refute_receive {:DOWN, ^monitor, :process, ^editor, _reason}, 0

      Process.demonitor(monitor, [:flush])
    end

    test "skips an already tracked editor buffer without crashing", %{tmp_dir: dir} do
      path = Path.join(dir, "tracked.ex")
      File.write!(path, "tracked")
      ctx = start_editor("tracked", file_path: path)
      editor = ctx.editor
      original = active_buffer(ctx)
      monitor = Process.monitor(editor)

      assert {:ok, ^original} = MingaEditor.ensure_buffer_for_path(path, editor)

      state = editor_state(ctx)
      assert state.workspace.buffers.active == original
      assert state.workspace.buffers.list == [original]
      refute_receive {:DOWN, ^monitor, :process, ^editor, _reason}, 0

      Process.demonitor(monitor, [:flush])
    end

    test "skips a buffer already tracked in an inactive tab", %{tmp_dir: dir} do
      path1 = Path.join(dir, "one.ex")
      path2 = Path.join(dir, "two.ex")
      File.write!(path1, "one")
      File.write!(path2, "two")
      ctx = start_editor("one", file_path: path1)
      editor = ctx.editor
      path1_pid = active_buffer(ctx)

      send_keys_sync(ctx, ":e #{path2}<CR>")
      path2_pid = active_buffer(ctx)
      Minga.API.execute(:tab_prev, editor)

      assert {:ok, ^path2_pid} = MingaEditor.ensure_buffer_for_path(path2, editor)

      state = editor_state(ctx)
      assert state.workspace.buffers.active == path1_pid
      assert state.workspace.buffers.list == [path1_pid]
      refute path2_pid in state.workspace.buffers.list
    end
  end
end
