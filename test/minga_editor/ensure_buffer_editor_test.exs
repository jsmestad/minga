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
  end
end
