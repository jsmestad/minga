defmodule MingaEditor.Commands.DiredTest do
  @moduledoc """
  Integration tests for the dired (Oil.nvim-style) directory buffer.

  Classification: these tests intentionally remain EditorCase integration coverage because they verify save interception, confirmation flow, real file creation/deletion/rename, navigation, and visible listing updates through the dired buffer.

  Tests the full keystroke-to-filesystem pipeline: opening dired via
  ex commands, navigating directories, editing filenames, and confirming
  file operations. Uses EditorCase for headless editor state.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options

  @moduletag :tmp_dir

  describe "[EditorCase integration] :dired — open directory buffer" do
    test "opens directory by path", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "hello.txt"), "")
      File.write!(Path.join(dir, "other.txt"), "")

      options_server = start_supervised!({Options, name: nil})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :dired, :autopair_block, false)

      ctx = start_editor("", options_server: options_server)
      state = send_keys_sync(ctx, ":dired #{dir}<CR>")

      assert state.workspace.keymap_scope == :dired
      assert state.workspace.dired.active?
      assert BufferProcess.get_option(active_buffer(ctx), :autopair_block) == false
      content = active_content(ctx)
      assert content =~ "hello.txt"
      assert content =~ "other.txt"
    end

    test "opening a regular file from dired inherits the editor options server", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "hello.txt"), "hello")

      options_server = start_supervised!({Options, name: nil})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :text, :autopair_block, false)

      ctx = start_editor("", options_server: options_server)
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      state = send_keys_sync(ctx, "<CR>")
      active = active_buffer(ctx)

      refute state.workspace.dired.active?
      assert BufferProcess.file_path(active) == Path.join(dir, "hello.txt")
      assert BufferProcess.get_option(active, :autopair_block) == false
    end

    test ":oil alias works the same", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "")

      ctx = start_editor("")
      state = send_keys_sync(ctx, ":oil #{dir}<CR>")

      assert state.workspace.keymap_scope == :dired
      assert state.workspace.dired.active?
    end

    test ":dired with subdir path opens that directory", %{tmp_dir: dir} do
      subdir = Path.join(dir, "sub")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "inner.txt"), "")
      File.write!(Path.join(dir, "outer.txt"), "")

      ctx = start_editor("")
      state = send_keys_sync(ctx, ":dired #{subdir}<CR>")

      assert state.workspace.dired.active?
      content = active_content(ctx)
      assert content =~ "inner.txt"
      refute content =~ "outer.txt"
    end
  end

  describe "[EditorCase integration] save interception" do
    test ":w on dired buffer does not write to disk", %{tmp_dir: dir} do
      file = Path.join(dir, "file.txt")
      File.write!(file, "original")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      state = send_keys_sync(ctx, ":w<CR>")

      assert state.workspace.dired.active?
      assert File.read!(file) == "original"
    end

    test ":w with no changes shows no-changes status", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "file.txt"), "")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")
      state = send_keys_sync(ctx, ":w<CR>")

      assert state.shell_state.status_msg =~ "No changes"
    end

    test ":w with changes enters confirmation mode", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "old_name.txt"), "content")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "ciwnew_name.txt<Esc>")

      state = send_keys_sync(ctx, ":w<CR>")

      assert state.workspace.dired.confirming?
      assert state.workspace.dired.pending_ops != []
      assert state.shell_state.status_msg =~ "apply? (y/n)"
    end
  end

  describe "[EditorCase integration] confirm-then-apply" do
    test "y confirms and applies rename", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "old.txt"), "content")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "0C")
      send_keys_sync(ctx, "new.txt<Esc>")
      send_keys_sync(ctx, ":w<CR>")

      state = send_keys_sync(ctx, "y")

      refute state.workspace.dired.confirming?
      assert File.exists?(Path.join(dir, "new.txt"))
      refute File.exists?(Path.join(dir, "old.txt"))
      assert state.shell_state.status_msg =~ "Applied"
    end

    test "n cancels without applying", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "keep.txt"), "content")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "ciwgone.txt<Esc>")
      send_keys_sync(ctx, ":w<CR>")

      state = send_keys_sync(ctx, "n")

      refute state.workspace.dired.confirming?
      assert File.exists?(Path.join(dir, "keep.txt"))
      refute File.exists?(Path.join(dir, "gone.txt"))
      assert state.shell_state.status_msg =~ "Cancelled"
    end

    test "Escape cancels confirmation", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "keep.txt"), "content")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "ciwgone.txt<Esc>")
      send_keys_sync(ctx, ":w<CR>")

      state = send_keys_sync(ctx, "<Esc>")

      refute state.workspace.dired.confirming?
      assert File.exists?(Path.join(dir, "keep.txt"))
    end

    test "y applies file deletion", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "delete_me.txt"), "gone")
      File.write!(Path.join(dir, "keep.txt"), "stay")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "dd")
      send_keys_sync(ctx, ":w<CR>")

      state = send_keys_sync(ctx, "y")

      refute state.workspace.dired.confirming?
      files = File.ls!(dir)
      assert length(files) < 2
      assert state.shell_state.status_msg =~ "Applied"
    end

    test "y applies new file creation", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "existing.txt"), "here")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "onewfile.txt<Esc>")
      send_keys_sync(ctx, ":w<CR>")

      state = send_keys_sync(ctx, "y")

      refute state.workspace.dired.confirming?
      assert File.exists?(Path.join(dir, "newfile.txt"))
    end

    test "y creates directory when name ends with /", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "file.txt"), "")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "onewdir/<Esc>")
      send_keys_sync(ctx, ":w<CR>")

      state = send_keys_sync(ctx, "y")

      refute state.workspace.dired.confirming?
      new_path = Path.join(dir, "newdir")
      assert File.dir?(new_path)
    end
  end

  describe "[EditorCase integration] navigation" do
    test "Enter on a directory navigates into it", %{tmp_dir: dir} do
      subdir = Path.join(dir, "sub")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "inner.txt"), "")
      File.write!(Path.join(dir, "outer.txt"), "")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "<CR>")

      content = active_content(ctx)
      assert content =~ "inner.txt"
    end

    test "- navigates to parent directory", %{tmp_dir: dir} do
      subdir = Path.join(dir, "child")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "deep.txt"), "")
      File.write!(Path.join(dir, "shallow.txt"), "")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{subdir}<CR>")

      state = send_keys_sync(ctx, "-")

      content = active_content(ctx)
      assert content =~ "shallow.txt"
      assert state.workspace.dired.dired.directory == Path.expand(dir)
    end

    test "q closes dired and returns to editor scope", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "file.txt"), "")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      state = send_keys_sync(ctx, "q")

      assert state.workspace.keymap_scope == :editor
      refute state.workspace.dired.active?
    end
  end

  describe "[EditorCase integration] display toggles" do
    test "g. toggles hidden files", %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".hidden"), "")
      File.write!(Path.join(dir, "visible.txt"), "")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      refute active_content(ctx) =~ ".hidden"

      send_keys_sync(ctx, "g.")

      assert active_content(ctx) =~ ".hidden"
    end

    test "gs cycles sort order", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "file.txt"), "")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      state = editor_state(ctx)
      assert state.workspace.dired.dired.sort_by == :name

      state = send_keys_sync(ctx, "gs")
      assert state.workspace.dired.dired.sort_by == :size
    end

    test "gd toggles detail columns", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "file.txt"), "content")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      refute active_content(ctx) =~ "rw"

      send_keys_sync(ctx, "gd")

      assert active_content(ctx) =~ "rw"
    end

    test "gr refreshes listing", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "initial.txt"), "")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      refute active_content(ctx) =~ "added_later.txt"

      File.write!(Path.join(dir, "added_later.txt"), "")
      send_keys_sync(ctx, "gr")

      assert active_content(ctx) =~ "added_later.txt"
    end
  end
end
