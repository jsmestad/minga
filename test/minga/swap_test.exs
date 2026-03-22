defmodule Minga.SwapTest do
  use ExUnit.Case, async: true

  alias Minga.Swap

  @moduletag :tmp_dir

  defp swap_opts(tmp_dir) do
    [swap_dir: tmp_dir, os_pid: 99_999]
  end

  describe "swap_path/2" do
    test "is deterministic for the same file path", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      assert Swap.swap_path("/foo/bar.ex", opts) == Swap.swap_path("/foo/bar.ex", opts)
    end

    test "different paths produce different swap paths", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      refute Swap.swap_path("/foo/bar.ex", opts) == Swap.swap_path("/foo/baz.ex", opts)
    end

    test "produces a .swap file in the swap directory", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      path = Swap.swap_path("/foo/bar.ex", opts)
      assert String.ends_with?(path, ".swap")
      assert String.starts_with?(path, tmp_dir)
    end

    test "includes OS PID in the filename", %{tmp_dir: tmp_dir} do
      path = Swap.swap_path("/foo/bar.ex", swap_dir: tmp_dir, os_pid: 12_345)
      assert String.contains?(Path.basename(path), ".12345.")
    end
  end

  describe "write/3 and read/1 round-trip" do
    test "preserves content and metadata", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      content = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      :ok = Swap.write("/tmp/test.ex", content, opts)

      swap_path = Swap.swap_path("/tmp/test.ex", opts)
      assert {:ok, meta, ^content} = Swap.read(swap_path)
      assert meta.path == "/tmp/test.ex"
      assert meta.os_pid == 99_999
      assert is_integer(meta.mtime)
      assert meta.swap_path == swap_path
    end

    test "preserves empty content", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      :ok = Swap.write("/tmp/empty.ex", "", opts)
      swap_path = Swap.swap_path("/tmp/empty.ex", opts)
      assert {:ok, _meta, ""} = Swap.read(swap_path)
    end

    test "preserves unicode content", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      content = "# 🎉 Héllo wörld\ndef café, do: :naïve\n"
      :ok = Swap.write("/tmp/unicode.ex", content, opts)
      swap_path = Swap.swap_path("/tmp/unicode.ex", opts)
      assert {:ok, _meta, ^content} = Swap.read(swap_path)
    end

    test "preserves content containing the old text delimiter", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      # This content would break a \n---\n text delimiter approach
      content = "before\n---\nafter\n---\nmore"
      :ok = Swap.write("/tmp/tricky.ex", content, opts)
      swap_path = Swap.swap_path("/tmp/tricky.ex", opts)
      assert {:ok, _meta, ^content} = Swap.read(swap_path)
    end

    test "preserves binary content with null bytes", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      content = <<0, 1, 2, 3, 0, 255>>
      :ok = Swap.write("/tmp/binary.dat", content, opts)
      swap_path = Swap.swap_path("/tmp/binary.dat", opts)
      assert {:ok, _meta, ^content} = Swap.read(swap_path)
    end

    test "atomic write leaves no .tmp file", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      :ok = Swap.write("/tmp/atomic.ex", "content", opts)
      tmp_files = Path.wildcard(Path.join(tmp_dir, "*.tmp"))
      assert tmp_files == []
    end
  end

  describe "read/1 error cases" do
    test "returns error for non-existent file" do
      assert {:error, :enoent} = Swap.read("/nonexistent/path.swap")
    end

    test "returns error for corrupt file", %{tmp_dir: tmp_dir} do
      corrupt_path = Path.join(tmp_dir, "corrupt.swap")
      File.write!(corrupt_path, "garbage data")
      assert {:error, :invalid_format} = Swap.read(corrupt_path)
    end

    test "returns error for valid magic but malformed header", %{tmp_dir: tmp_dir} do
      corrupt_path = Path.join(tmp_dir, "bad_header.swap")
      # Valid magic, but header content is garbage
      header = "bad header data"
      data = <<"MINGA_SWAP_V1\n", byte_size(header)::32-big, header::binary, "content">>
      File.write!(corrupt_path, data)
      assert {:error, :invalid_format} = Swap.read(corrupt_path)
    end
  end

  describe "delete/2" do
    test "removes the swap file", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      :ok = Swap.write("/tmp/del.ex", "content", opts)
      swap_path = Swap.swap_path("/tmp/del.ex", opts)
      assert File.exists?(swap_path)

      :ok = Swap.delete("/tmp/del.ex", opts)
      refute File.exists?(swap_path)
    end

    test "is idempotent for non-existent files", %{tmp_dir: tmp_dir} do
      opts = swap_opts(tmp_dir)
      assert :ok = Swap.delete("/tmp/never_existed.ex", opts)
    end
  end
end
