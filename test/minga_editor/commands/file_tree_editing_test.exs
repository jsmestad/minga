defmodule MingaEditor.Commands.FileTreeEditingTest do
  @moduledoc """
  Tests for file tree inline editing commands: new file, new folder,
  rename, confirm, and cancel.

  Uses EditorCase with tmp_dir for real filesystem operations.
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer

  @moduletag :tmp_dir

  describe "new file (a)" do
    test "enters new-file editing mode", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "a")

      assert state.workspace.file_tree.editing != nil
      assert state.workspace.file_tree.editing.type == :new_file
      assert state.workspace.file_tree.editing.text == ""
    end

    test "creates file on disk after typing name and pressing Enter", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      _state = send_keys_sync(ctx, "a")
      state = send_keys_sync(ctx, "newfile.txt<Enter>")

      assert state.workspace.file_tree.editing == nil

      expected = Path.join(dir, "newfile.txt")
      assert File.exists?(expected), "Expected newfile.txt to exist at #{expected}"
    end
  end

  describe "new folder (A)" do
    test "enters new-folder editing mode", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "A")

      assert state.workspace.file_tree.editing != nil
      assert state.workspace.file_tree.editing.type == :new_folder
    end

    test "creates directory on disk after typing name and pressing Enter", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      _state = send_keys_sync(ctx, "A")
      state = send_keys_sync(ctx, "newfolder<Enter>")

      assert state.workspace.file_tree.editing == nil

      expected = Path.join(dir, "newfolder")
      assert File.dir?(expected), "Expected newfolder to exist at #{expected}"
    end
  end

  describe "rename (R)" do
    test "enters rename editing mode with current name pre-filled", %{tmp_dir: dir} do
      file = Path.join(dir, "target.txt")
      File.write!(file, "content")

      ctx = start_editor("content", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "R")

      assert state.workspace.file_tree.editing != nil
      assert state.workspace.file_tree.editing.type == :rename
      assert state.workspace.file_tree.editing.original_name != nil
    end

    test "renames file on disk after changing name", %{tmp_dir: dir} do
      file = Path.join(dir, "target.txt")
      File.write!(file, "content")

      ctx = start_editor("content", file_path: file, project_root: dir)

      # Open tree (reveals active file automatically), press R
      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "R")
      name = state.workspace.file_tree.editing.text

      # Clear pre-filled text with backspaces, then type new name
      backspaces = String.duplicate("<BS>", String.length(name))
      state = send_keys_sync(ctx, "#{backspaces}renamed.txt<Enter>")

      assert state.workspace.file_tree.editing == nil

      new_path = Path.join(dir, "renamed.txt")
      assert File.exists?(new_path), "Expected renamed.txt to exist"
      refute File.exists?(file), "Expected target.txt to no longer exist"
    end

    test "rename does not overwrite an existing sibling", %{tmp_dir: dir} do
      file = Path.join(dir, "target.txt")
      existing = Path.join(dir, "existing.txt")
      File.write!(file, "content")
      File.write!(existing, "existing")

      ctx = start_editor("content", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "R")
      backspaces = String.duplicate("<BS>", String.length(state.workspace.file_tree.editing.text))
      state = send_keys_sync(ctx, "#{backspaces}existing.txt<Enter>")

      assert state.workspace.file_tree.editing == nil
      assert File.read!(file) == "content"
      assert File.read!(existing) == "existing"
    end
  end

  describe "rename retargets open buffers" do
    test "rename retargets a dirty open file buffer without writing its contents", %{tmp_dir: dir} do
      file = Path.join(dir, "target.txt")
      renamed = Path.join(dir, "renamed.txt")
      File.write!(file, "content")

      ctx = start_editor("content", file_path: file, project_root: dir)
      buffer = active_buffer(ctx)

      assert is_pid(buffer)
      :ok = Buffer.insert_char(buffer, "!")
      assert Buffer.dirty?(buffer)

      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "R")
      backspaces = String.duplicate("<BS>", String.length(state.workspace.file_tree.editing.text))
      state = send_keys_sync(ctx, "#{backspaces}renamed.txt<Enter>")

      assert state.workspace.file_tree.editing == nil
      assert Buffer.file_path(buffer) == renamed
      assert Buffer.dirty?(buffer)
      assert File.read!(renamed) == "content"
      refute File.exists?(file)

      assert :ok = Buffer.save(buffer)
      assert File.read!(renamed) == "!content"
    end

    test "rename leaves a dirty open buffer on the original path when destination exists", %{
      tmp_dir: dir
    } do
      file = Path.join(dir, "target.txt")
      existing = Path.join(dir, "existing.txt")
      File.write!(file, "content")
      File.write!(existing, "existing")

      ctx = start_editor("content", file_path: file, project_root: dir)
      buffer = active_buffer(ctx)

      :ok = Buffer.insert_char(buffer, "!")
      assert Buffer.dirty?(buffer)

      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "R")
      backspaces = String.duplicate("<BS>", String.length(state.workspace.file_tree.editing.text))
      state = send_keys_sync(ctx, "#{backspaces}existing.txt<Enter>")

      assert state.workspace.file_tree.editing == nil
      assert Buffer.file_path(buffer) == file
      assert Buffer.dirty?(buffer)
      assert File.read!(file) == "content"
      assert File.read!(existing) == "existing"
    end
  end

  describe "cancel editing" do
    test "Escape cancels without filesystem changes", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      _state = send_keys_sync(ctx, "a")
      _state = send_keys_sync(ctx, "partial")
      state = send_keys_sync(ctx, "<Esc>")

      assert state.workspace.file_tree.editing == nil

      refute File.exists?(Path.join(dir, "partial")),
             "No file should be created when editing is cancelled"
    end

    test "confirm with empty text cancels", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      _state = send_keys_sync(ctx, "a")
      state = send_keys_sync(ctx, "<Enter>")

      assert state.workspace.file_tree.editing == nil
    end

    test "Backspace on empty text cancels editing", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      _state = send_keys_sync(ctx, "a")
      state = send_keys_sync(ctx, "<BS>")

      assert state.workspace.file_tree.editing == nil
    end
  end

  describe "rename to same name cancels" do
    test "no filesystem operation when name unchanged", %{tmp_dir: dir} do
      file = Path.join(dir, "same.txt")
      File.write!(file, "content")

      ctx = start_editor("content", file_path: file, project_root: dir)

      _state = send_keys_sync(ctx, "<SPC>op")
      _state = send_keys_sync(ctx, "R")
      state = send_keys_sync(ctx, "<Enter>")

      assert state.workspace.file_tree.editing == nil
      assert File.exists?(file), "File should still exist unchanged"
    end
  end
end
