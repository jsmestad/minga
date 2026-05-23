defmodule MingaEditor.Extension.EditorAPITest do
  use Minga.Test.EditorCase, async: true

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.State, as: EditorState

  describe "set_status/2" do
    test "sets transient status message" do
      ctx = start_editor("hello world")
      state = editor_state(ctx)

      new_state = EditorAPI.set_status(state, "Test status message")

      assert EditorState.status_msg(new_state) == "Test status message"
    end
  end

  describe "open_file/2" do
    test "opens an existing file and makes its buffer active" do
      path = write_temp_file("extension_editor_api_test", "file content here")
      ctx = start_editor("original content")
      state = editor_state(ctx)

      new_state = EditorAPI.open_file(state, path)

      active_buf = new_state.workspace.buffers.active
      assert is_pid(active_buf)
      assert Minga.Buffer.file_path(active_buf) == path
    end

    test "does not crash on nonexistent file" do
      ctx = start_editor("original content")
      state = editor_state(ctx)

      new_state = EditorAPI.open_file(state, "/nonexistent/path/to/file.ex")

      assert %EditorState{} = new_state
    end
  end

  describe "navigate_to/4" do
    test "opens file and moves cursor to specified line" do
      content = "line one\nline two\nline three\nline four\n"
      path = write_temp_file("editor_api_nav_test", content)
      ctx = start_editor("original")
      state = editor_state(ctx)

      new_state = EditorAPI.navigate_to(state, path, 2, 0)

      active_buf = new_state.workspace.buffers.active
      assert is_pid(active_buf)
      assert Minga.Buffer.cursor(active_buf) == {2, 0}
    end
  end

  describe "focus_buffer/2" do
    test "returns state unchanged when buffer is not in any window" do
      ctx = start_editor("hello")
      state = editor_state(ctx)
      fake_pid = spawn(fn -> Process.sleep(:infinity) end)

      new_state = EditorAPI.focus_buffer(state, fake_pid)

      assert new_state.workspace.windows.active == state.workspace.windows.active

      Process.exit(fake_pid, :kill)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp write_temp_file(prefix, content) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "#{prefix}_#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
