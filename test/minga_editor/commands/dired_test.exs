defmodule MingaEditor.Commands.DiredTest do
  @moduledoc """
  Integration tests for the dired (Oil.nvim-style) directory buffer.

  These tests keep filesystem mutations, input routing, and visible listing updates at the EditorCase boundary. Pure listing parsing and sorting live in `test/minga/dired_test.exs`.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options

  @moduletag :tmp_dir

  test "opens dired with filetype options and routes directory navigation", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "hello.txt"), "hello")
    File.write!(Path.join(dir, "other.txt"), "")
    options_server = start_supervised!({Options, name: nil})

    assert {:ok, false} = Options.set_for_filetype(options_server, :dired, :autopair_block, false)
    assert {:ok, false} = Options.set_for_filetype(options_server, :text, :autopair_block, false)

    ctx = start_editor("", options_server: options_server)
    open_dired(ctx, dir)

    assert BufferProcess.get_option(active_buffer(ctx), :autopair_block) == false
    assert active_content(ctx) =~ "hello.txt"
    assert active_content(ctx) =~ "other.txt"

    send_keys_sync(ctx, "<CR>")
    active = active_buffer(ctx)
    assert active_content(ctx) == "hello"
    assert BufferProcess.file_path(active) == Path.join(dir, "hello.txt")
    assert BufferProcess.get_option(active, :autopair_block) == false

    subdir = Path.join(dir, "sub")
    File.mkdir_p!(subdir)
    File.write!(Path.join(subdir, "inner.txt"), "")
    open_dired(ctx, subdir)
    send_keys_sync(ctx, "-")
    assert active_content(ctx) =~ "hello.txt"
    refute active_content(ctx) =~ "inner.txt"
  end

  test "q closes dired and returns to editor scope", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "file.txt"), "")

    ctx = start_editor("")
    open_dired(ctx, dir)
    send_keys_sync(ctx, "q")

    refute active_content(ctx) =~ "file.txt"
  end

  test "save interception confirms or applies dired mutations", %{tmp_dir: dir} do
    cancel_dir = Path.join(dir, "cancel")
    rename_dir = Path.join(dir, "rename")
    delete_dir = Path.join(dir, "delete")
    add_dir = Path.join(dir, "add")
    Enum.each([cancel_dir, rename_dir, delete_dir, add_dir], &File.mkdir_p!/1)
    File.write!(Path.join(cancel_dir, "keep.txt"), "content")
    File.write!(Path.join(rename_dir, "old.txt"), "content")
    File.write!(Path.join(delete_dir, "delete_me.txt"), "gone")
    File.write!(Path.join(delete_dir, "keep.txt"), "stay")
    File.write!(Path.join(add_dir, "existing.txt"), "here")

    ctx = start_editor("")

    open_dired(ctx, cancel_dir)
    state = send_ex_sync(ctx, "w")
    assert state.shell_state.status_msg =~ "No changes"

    send_keys_sync(ctx, "ciwgone.txt<Esc>")
    state = send_ex_sync(ctx, "w")
    assert state.workspace.dired.confirming?
    assert state.workspace.dired.pending_ops != []
    assert state.shell_state.status_msg =~ "apply? (y/n)"

    state = send_keys_sync(ctx, "n")
    refute state.workspace.dired.confirming?
    assert File.exists?(Path.join(cancel_dir, "keep.txt"))
    refute File.exists?(Path.join(cancel_dir, "gone.txt"))

    open_dired(ctx, rename_dir)
    send_keys_sync(ctx, "0C")
    send_keys_sync(ctx, "new.txt<Esc>")
    send_ex_sync(ctx, "w")
    state = send_keys_sync(ctx, "y")
    refute state.workspace.dired.confirming?
    assert File.exists?(Path.join(rename_dir, "new.txt"))
    refute File.exists?(Path.join(rename_dir, "old.txt"))

    open_dired(ctx, delete_dir)
    send_keys_sync(ctx, "dd")
    send_ex_sync(ctx, "w")
    state = send_keys_sync(ctx, "y")
    refute state.workspace.dired.confirming?
    assert Enum.count(File.ls!(delete_dir)) < 2

    open_dired(ctx, add_dir)
    BufferProcess.replace_content(active_buffer(ctx), "existing.txt\nnewfile.txt\nnewdir/")
    send_ex_sync(ctx, "w")
    state = send_keys_sync(ctx, "y")
    refute state.workspace.dired.confirming?
    assert File.exists?(Path.join(add_dir, "newfile.txt"))
    assert File.dir?(Path.join(add_dir, "newdir"))
  end

  test "display toggles update the listing state", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".hidden"), "")
    File.write!(Path.join(dir, "visible.txt"), "")
    File.write!(Path.join(dir, "z-small.txt"), "a")
    File.write!(Path.join(dir, "a-big.txt"), String.duplicate("x", 1000))

    ctx = start_editor("")
    open_dired(ctx, dir)
    refute active_content(ctx) =~ ".hidden"

    send_keys_sync(ctx, "g.")
    assert active_content(ctx) =~ ".hidden"

    send_keys_sync(ctx, "gs")
    lines = String.split(active_content(ctx), "\n", trim: true)
    small_index = Enum.find_index(lines, &String.contains?(&1, "z-small.txt"))
    big_index = Enum.find_index(lines, &String.contains?(&1, "a-big.txt"))
    assert small_index < big_index

    send_keys_sync(ctx, "gd")
    assert active_content(ctx) =~ "rw"

    refute active_content(ctx) =~ "added_later.txt"
    File.write!(Path.join(dir, "added_later.txt"), "")
    send_keys_sync(ctx, "gr")
    assert active_content(ctx) =~ "added_later.txt"
  end

  defp open_dired(ctx, path) do
    send_ex_sync(ctx, "dired #{path}")
  end
end
