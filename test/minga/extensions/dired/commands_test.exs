defmodule Minga.Extensions.Dired.CommandsTest do
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
  alias Minga.Extensions.Dired.Commands
  alias Minga.Extensions.Dired.Input
  alias Minga.Extensions.Dired.KeymapScope

  @moduletag :tmp_dir

  setup do
    source = {:extension, :dired}
    Minga.Command.Registry.register_provider(Minga.Command.Registry, source, Commands)
    Minga.Keymap.Scope.register(source, KeymapScope)
    MingaEditor.Input.register_handler(source, Input, priority: 70)

    on_exit(fn ->
      Minga.Extension.ContributionCleanup.unregister_source(source)
      MingaEditor.Input.unregister_source(source)
    end)

    :ok
  end

  describe "[EditorCase integration] :dired — open directory buffer" do
    test "opens directory by path", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "hello.txt"), "")
      File.write!(Path.join(dir, "other.txt"), "")

      options_server = start_supervised!({Options, name: nil})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :dired, :autopair_block, false)

      ctx = start_editor("", options_server: options_server)
      send_keys_sync(ctx, ":dired #{dir}<CR>")

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

      send_keys_sync(ctx, "<CR>")
      active = active_buffer(ctx)

      assert active_content(ctx) == "hello"
      assert BufferProcess.file_path(active) == Path.join(dir, "hello.txt")
      assert BufferProcess.get_option(active, :autopair_block) == false
    end
  end

  describe "[EditorCase integration] save interception" do
    test ":w on dired buffer does not write to disk", %{tmp_dir: dir} do
      file = Path.join(dir, "file.txt")
      File.write!(file, "original")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      state = send_keys_sync(ctx, ":w<CR>")

      assert File.read!(file) == "original"
      assert state.shell_state.status_msg =~ "No changes"
    end

    test ":w with changes enters confirmation mode", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "old_name.txt"), "content")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "ciwnew_name.txt<Esc>")

      state = send_keys_sync(ctx, ":w<CR>")

      dired_state = state.workspace.feature_state[:dired]
      assert dired_state.confirming?
      assert dired_state.pending_ops != []
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

      dired_state = state.workspace.feature_state[:dired]
      refute dired_state.confirming?
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

      dired_state = state.workspace.feature_state[:dired]
      refute dired_state.confirming?
      assert File.exists?(Path.join(dir, "keep.txt"))
      refute File.exists?(Path.join(dir, "gone.txt"))
      assert state.shell_state.status_msg =~ "Cancelled"
    end

    test "y applies file deletion", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "delete_me.txt"), "gone")
      File.write!(Path.join(dir, "keep.txt"), "stay")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "dd")
      send_keys_sync(ctx, ":w<CR>")

      state = send_keys_sync(ctx, "y")

      dired_state = state.workspace.feature_state[:dired]
      refute dired_state.confirming?
      files = File.ls!(dir)
      assert length(files) < 2
      assert state.shell_state.status_msg =~ "Applied"
    end

    test "y applies added file and directory entries", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "existing.txt"), "here")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      BufferProcess.replace_content(active_buffer(ctx), "existing.txt\nnewfile.txt\nnewdir/")
      send_keys_sync(ctx, ":w<CR>")

      state = send_keys_sync(ctx, "y")

      dired_state = state.workspace.feature_state[:dired]
      refute dired_state.confirming?
      assert File.exists?(Path.join(dir, "newfile.txt"))
      assert File.dir?(Path.join(dir, "newdir"))
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

      send_keys_sync(ctx, "-")

      content = active_content(ctx)
      assert content =~ "shallow.txt"
      refute content =~ "deep.txt"
    end

    test "q closes dired and returns to editor scope", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "file.txt"), "")

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")

      send_keys_sync(ctx, "q")

      refute active_content(ctx) =~ "file.txt"
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

    test "gs shows entries in the next sort order", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "z-small.txt"), "a")
      File.write!(Path.join(dir, "a-big.txt"), String.duplicate("x", 1000))

      ctx = start_editor("")
      send_keys_sync(ctx, ":dired #{dir}<CR>")
      send_keys_sync(ctx, "gs")

      lines = String.split(active_content(ctx), "\n", trim: true)
      small_index = Enum.find_index(lines, &String.contains?(&1, "z-small.txt"))
      big_index = Enum.find_index(lines, &String.contains?(&1, "a-big.txt"))

      assert small_index < big_index
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
