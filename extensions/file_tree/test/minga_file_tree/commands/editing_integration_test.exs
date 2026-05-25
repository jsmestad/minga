defmodule MingaFileTree.CommandsEditingIntegrationTest do
  @moduledoc """
  EditorCase smoke tests for file tree inline editing key routing.

  Classification: deterministic editing state transitions live in `FileTreeEditingTest`; these tests stay full-editor because they prove user-facing key routing still creates and renames real filesystem entries through the visible file tree.
  """

  use Minga.Test.EditorCase, async: true

  @moduletag :tmp_dir

  describe "[EditorCase integration] file tree editing key routing" do
    test "a creates a file on disk after typing a name and pressing Enter", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      _state = send_keys_sync(ctx, "a")
      state = send_keys_sync(ctx, "newfile.txt<Enter>")

      assert MingaEditor.State.file_tree_state(state).editing == nil

      expected = Path.join(dir, "newfile.txt")
      assert File.exists?(expected), "Expected newfile.txt to exist at #{expected}"
    end

    test "A creates a folder on disk after typing a name and pressing Enter", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "A")

      assert MingaEditor.State.file_tree_state(state).editing.type == :new_folder

      state = send_keys_sync(ctx, "newfolder<Enter>")

      assert MingaEditor.State.file_tree_state(state).editing == nil

      expected = Path.join(dir, "newfolder")
      assert File.dir?(expected), "Expected newfolder to exist at #{expected}"
    end

    test "R renames a file on disk after replacing the inline name", %{tmp_dir: dir} do
      file = Path.join(dir, "target.txt")
      File.write!(file, "content")

      ctx = start_editor("content", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "R")

      backspaces =
        String.duplicate(
          "<BS>",
          String.length(MingaEditor.State.file_tree_state(state).editing.text)
        )

      state = send_keys_sync(ctx, "#{backspaces}renamed.txt<Enter>")

      assert MingaEditor.State.file_tree_state(state).editing == nil

      new_path = Path.join(dir, "renamed.txt")
      assert File.exists?(new_path), "Expected renamed.txt to exist"
      refute File.exists?(file), "Expected target.txt to no longer exist"
    end
  end
end
