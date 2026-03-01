defmodule Minga.Editor.StatusMsgTest do
  @moduledoc """
  Integration tests for the minibuffer status message (Doom-style echo area).
  """

  use Minga.Test.EditorCase, async: true

  @tag :tmp_dir
  test "successful save shows 'Wrote <path>' in minibuffer", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "status.txt")
    File.write!(path, "hello")

    ctx = start_editor("hello", file_path: path)
    send_keys(ctx, ":w<CR>")

    mb = minibuffer(ctx)
    assert String.contains?(mb, "Wrote")
    assert String.contains?(mb, "status.txt")
  end

  @tag :tmp_dir
  test "save conflict shows warning in minibuffer", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "conflict.txt")
    File.write!(path, "original")

    ctx = start_editor("original", file_path: path)

    # Simulate external modification (mtime must advance)
    :timer.sleep(1100)
    File.write!(path, "externally modified")

    send_keys(ctx, ":w<CR>")

    mb = minibuffer(ctx)
    assert String.contains?(mb, "WARNING")
    assert String.contains?(mb, ":w!")
  end

  @tag :tmp_dir
  test "force save shows confirmation in minibuffer", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "force.txt")
    File.write!(path, "original")

    ctx = start_editor("original", file_path: path)

    # Simulate external modification
    :timer.sleep(1100)
    File.write!(path, "externally modified")

    send_keys(ctx, ":w!<CR>")

    mb = minibuffer(ctx)
    assert String.contains?(mb, "Wrote")
    assert String.contains?(mb, "force")
  end

  @tag :tmp_dir
  test "reload shows confirmation in minibuffer", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "reload.txt")
    File.write!(path, "original")

    ctx = start_editor("original", file_path: path)
    File.write!(path, "reloaded")

    send_keys(ctx, ":e!<CR>")

    mb = minibuffer(ctx)
    assert String.contains?(mb, "Reloaded")
  end

  @tag :tmp_dir
  test "status message clears on next keypress", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "clear.txt")
    File.write!(path, "hello")

    ctx = start_editor("hello", file_path: path)
    send_keys(ctx, ":w<CR>")

    mb = minibuffer(ctx)
    assert String.contains?(mb, "Wrote")

    # Press any key — message should clear
    send_key(ctx, ?j)

    mb = minibuffer(ctx)
    refute String.contains?(mb, "Wrote")
  end

  test "save on scratch buffer shows error in minibuffer" do
    ctx = start_editor("scratch content")
    send_keys(ctx, ":w<CR>")

    mb = minibuffer(ctx)
    assert String.contains?(mb, "No file name")
  end
end
