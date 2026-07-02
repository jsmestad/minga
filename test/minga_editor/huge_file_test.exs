defmodule MingaEditor.HugeFileTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Config.Options
  alias MingaEditor.HugeFile

  @moduletag :tmp_dir

  @limit 100

  setup do
    {:ok, server} =
      Options.start_link(name: :"huge_file_opts_#{System.unique_integer([:positive])}")

    Options.set(server, :max_file_size, @limit)
    %{server: server}
  end

  defp write_file(dir, name, byte_count) do
    path = Path.join(dir, name)
    File.write!(path, String.duplicate("a", byte_count))
    path
  end

  defp track(pid) do
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  describe "oversize/2 (pre-read stat gate)" do
    test "refuses a file strictly larger than the limit", %{tmp_dir: dir} do
      path = write_file(dir, "big.txt", @limit + 1)
      assert HugeFile.oversize(path, @limit) == {:refuse, @limit + 1, @limit}
    end

    test "opens a file exactly at the limit (boundary)", %{tmp_dir: dir} do
      path = write_file(dir, "edge.txt", @limit)
      assert HugeFile.oversize(path, @limit) == :ok
    end

    test "opens a file under the limit", %{tmp_dir: dir} do
      path = write_file(dir, "small.txt", @limit - 1)
      assert HugeFile.oversize(path, @limit) == :ok
    end

    test "passes through a missing file (normal open handles enoent)", %{tmp_dir: dir} do
      assert HugeFile.oversize(Path.join(dir, "nope.txt"), @limit) == :ok
    end

    test "passes through a directory", %{tmp_dir: dir} do
      assert HugeFile.oversize(dir, @limit) == :ok
    end
  end

  describe "guard/3 refusal path" do
    test "an over-limit file yields a text-only refusal buffer and never opens the file",
         %{tmp_dir: dir, server: server} do
      path = write_file(dir, "huge.log", @limit + 500)

      open_fun = fn -> flunk("open_fun ran for an over-limit file") end

      assert {:ok, pid} = HugeFile.guard(path, server, open_fun)
      track(pid)

      # AC1/AC4: the huge file was never read into a buffer — no buffer is
      # registered for its path, so no gap buffer and no tree-sitter parse.
      assert Buffer.pid_for_path(Path.expand(path)) == :not_found

      # The refusal surface is an ordinary read-only, file-less buffer.
      assert Buffer.read_only?(pid)
      assert Buffer.file_path(pid) == nil

      content = Buffer.content(pid)
      assert content =~ "File too large for Minga V1"
      assert content =~ Path.expand(path)
      assert content =~ "another editor"
    end
  end

  describe "guard/3 open path" do
    test "an under-limit file opens normally with byte-identical content",
         %{tmp_dir: dir, server: server} do
      path = write_file(dir, "ok.txt", @limit - 1)
      expected = File.read!(path)

      open_fun = fn ->
        Buffer.ensure_for_path(path, Minga.Events.default_registry(), options_server: server)
      end

      assert {:ok, pid} = HugeFile.guard(path, server, open_fun)
      track(pid)

      assert Buffer.pid_for_path(Path.expand(path)) == {:ok, pid}
      assert Buffer.content(pid) == expected
    end

    test "a file exactly at the limit opens (boundary)", %{tmp_dir: dir, server: server} do
      path = write_file(dir, "edge.txt", @limit)

      open_fun = fn ->
        Buffer.ensure_for_path(path, Minga.Events.default_registry(), options_server: server)
      end

      assert {:ok, pid} = HugeFile.guard(path, server, open_fun)
      track(pid)

      assert Buffer.pid_for_path(Path.expand(path)) == {:ok, pid}
    end
  end

  describe "message/3" do
    test "contains the message, the path, and the open-in-another-editor suggestion" do
      msg = HugeFile.message("/tmp/whatever.bin", 20_000_000, 10_485_760)

      assert msg =~ "File too large for Minga V1"
      assert msg =~ "/tmp/whatever.bin"
      assert msg =~ "another editor"
      assert msg =~ ":max_file_size"
    end
  end
end
