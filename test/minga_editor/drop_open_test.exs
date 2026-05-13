defmodule MingaEditor.DropOpenTest do
  @moduledoc """
  Tests for the gui_action {:open_file, path} handler's file-vs-directory
  branching. This handler is triggered by drag-and-drop from Finder, the
  macOS Open With menu, and `open -a Minga` from the terminal.
  """

  use Minga.Test.EditorCase, async: true

  describe "drop file" do
    @tag :tmp_dir
    test "opening a file via gui_action creates a new buffer", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dropped.txt")
      File.write!(path, "dropped content")

      ctx = start_editor("initial")

      send(ctx.editor, {:minga_input, {:gui_action, {:open_file, path}}})
      state = editor_state(ctx)

      assert length(state.workspace.buffers.list) == 2
      assert Minga.Buffer.Server.file_path(state.workspace.buffers.active) == path
    end

    @tag :tmp_dir
    test "opening multiple files via gui_action opens each, last one active", %{tmp_dir: tmp_dir} do
      paths =
        for i <- 1..3 do
          p = Path.join(tmp_dir, "file#{i}.txt")
          File.write!(p, "content #{i}")
          p
        end

      ctx = start_editor("initial")

      for path <- paths do
        send(ctx.editor, {:minga_input, {:gui_action, {:open_file, path}}})
      end

      state = editor_state(ctx)

      assert length(state.workspace.buffers.list) == 4
      assert Minga.Buffer.Server.file_path(state.workspace.buffers.active) == List.last(paths)
    end

    @tag :tmp_dir
    test "opening an already-open file switches to it without duplicating", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "existing.txt")
      File.write!(path, "existing")

      ctx = start_editor("existing", file_path: path)
      initial_count = buffer_count(ctx)

      send(ctx.editor, {:minga_input, {:gui_action, {:open_file, path}}})
      state = editor_state(ctx)

      assert length(state.workspace.buffers.list) == initial_count
      assert Minga.Buffer.Server.file_path(state.workspace.buffers.active) == path
    end
  end
end
