defmodule Minga.Buffer.BuftypeIntegrationTest do
  @moduledoc """
  Integration tests for the buffer_type system.

  Verifies that nofile/nowrite buffers block editing and saving while
  file-backed buffers remain unaffected.
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Server, as: BufferServer

  describe "nofile buffer blocks editing" do
    test "insert mode is blocked with read-only message" do
      {:ok, buf} =
        BufferServer.start_link(
          content: "read only content",
          buffer_type: :nofile,
          read_only: true
        )

      ctx = start_editor_with_buffer(buf)

      # Try entering insert mode
      state = send_key_sync(ctx, ?i)
      assert state.vim.mode == :normal
      assert state.status_msg =~ "read-only"
    end

    test "dd is blocked on read-only nofile buffer" do
      {:ok, buf} =
        BufferServer.start_link(
          content: "line one\nline two\nline three",
          buffer_type: :nofile,
          read_only: true
        )

      original = BufferServer.content(buf)
      ctx = start_editor_with_buffer(buf)

      send_keys_sync(ctx, "dd")
      assert BufferServer.content(buf) == original
    end

    test "save is blocked on nofile buffer" do
      {:ok, buf} =
        BufferServer.start_link(
          content: "no file",
          buffer_type: :nofile
        )

      assert BufferServer.save(buf) == {:error, :buffer_not_saveable}
    end

    test "force_save is blocked on nofile buffer" do
      {:ok, buf} =
        BufferServer.start_link(
          content: "no file",
          buffer_type: :nofile
        )

      assert BufferServer.force_save(buf) == {:error, :buffer_not_saveable}
    end
  end

  describe "nowrite buffer blocks save but allows editing" do
    test "save is blocked on nowrite buffer" do
      {:ok, buf} =
        BufferServer.start_link(
          content: "nowrite content",
          buffer_type: :nowrite
        )

      assert BufferServer.force_save(buf) == {:error, :buffer_not_saveable}
    end
  end

  describe "file-backed buffers are unaffected" do
    @tag :tmp_dir
    test "file buffer saves normally", %{tmp_dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "hello")

      ctx = start_editor("hello", file_path: path)
      buf = ctx.buffer

      assert BufferServer.buffer_type(buf) == :file

      # Enter insert mode, type, escape, save
      send_keys_sync(ctx, "A world")
      send_keys_sync(ctx, "<Esc>")
      send_keys_sync(ctx, ":w<CR>")

      assert File.read!(path) =~ "world"
    end

    @tag :tmp_dir
    test "file buffer tracks dirty state", %{tmp_dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "hello")

      ctx = start_editor("hello", file_path: path)
      buf = ctx.buffer

      refute BufferServer.dirty?(buf)

      send_keys_sync(ctx, "iX")
      send_keys_sync(ctx, "<Esc>")

      assert BufferServer.dirty?(buf)
    end

    @tag :tmp_dir
    test "file buffer undo works", %{tmp_dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "hello")

      ctx = start_editor("hello", file_path: path)
      buf = ctx.buffer

      send_keys_sync(ctx, "iX")
      send_keys_sync(ctx, "<Esc>")
      assert BufferServer.content(buf) =~ "X"

      send_key_sync(ctx, ?u)
      refute BufferServer.content(buf) =~ "X"
    end
  end
end
