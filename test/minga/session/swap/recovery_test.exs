defmodule Minga.Session.Swap.RecoveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.Session.Swap
  alias Minga.Session.Swap.Recovery

  @moduletag :tmp_dir

  defp write_swap_file(tmp_dir, file_path, content, opts \\ []) do
    os_pid = Keyword.get(opts, :os_pid, 99_999)
    mtime = Keyword.get(opts, :mtime, System.os_time(:second))

    header = "path=#{file_path}\nos_pid=#{os_pid}\nmtime=#{mtime}"
    header_len = byte_size(header)
    data = <<"MINGA_SWAP_V1\n", header_len::32-big, header::binary, content::binary>>

    hash = :crypto.hash(:sha256, file_path) |> Base.hex_encode32(case: :lower, padding: false)
    swap_path = Path.join(tmp_dir, "#{hash}.#{os_pid}.swap")
    File.write!(swap_path, data)
    swap_path
  end

  defp scan_opts(tmp_dir, pid_alive? \\ fn _ -> false end) do
    [swap_dir: tmp_dir, pid_alive?: pid_alive?]
  end

  describe "scan/1" do
    test "returns empty list when swap directory doesn't exist" do
      assert Recovery.scan(swap_dir: "/nonexistent/path") == []
    end

    test "returns empty list when swap directory is empty", %{tmp_dir: tmp_dir} do
      assert Recovery.scan(scan_opts(tmp_dir)) == []
    end

    test "finds recoverable swap files for existing original files", %{tmp_dir: tmp_dir} do
      original = Path.join(tmp_dir, "original.ex")
      File.write!(original, "original content")

      swap_path = write_swap_file(tmp_dir, original, "modified content")

      results = Recovery.scan(scan_opts(tmp_dir))
      assert Enum.count(results) == 1
      assert hd(results).path == original
      assert hd(results).swap_path == swap_path
    end

    test "skips swap files whose original file was deleted", %{tmp_dir: tmp_dir} do
      swap_path = write_swap_file(tmp_dir, "/nonexistent/deleted.ex", "content")
      assert File.exists?(swap_path)

      results = Recovery.scan(scan_opts(tmp_dir))
      assert results == []
      # Swap file should be cleaned up
      refute File.exists?(swap_path)
    end

    test "skips swap files owned by a still-running process", %{tmp_dir: tmp_dir} do
      original = Path.join(tmp_dir, "active.ex")
      File.write!(original, "content")

      alive_pid = 12_345
      write_swap_file(tmp_dir, original, "modified", os_pid: alive_pid)

      # PID is alive: swap file should be skipped
      results = Recovery.scan(scan_opts(tmp_dir, fn pid -> pid == alive_pid end))
      assert results == []
    end

    test "skips and cleans up corrupt swap files", %{tmp_dir: tmp_dir} do
      corrupt_path = Path.join(tmp_dir, "corrupt.swap")
      File.write!(corrupt_path, "garbage")

      results = Recovery.scan(scan_opts(tmp_dir))
      assert results == []
      refute File.exists?(corrupt_path)
    end

    test "ignores non-.swap files in the directory", %{tmp_dir: tmp_dir} do
      other_file = Path.join(tmp_dir, "random.txt")
      File.write!(other_file, "not a swap file")

      results = Recovery.scan(scan_opts(tmp_dir))
      assert results == []
      # The file should NOT be deleted
      assert File.exists?(other_file)
    end

    test "removes only recognized temporary files whose owner is dead", %{tmp_dir: tmp_dir} do
      dead_pid = 99_991
      live_pid = 99_992

      assert {:ok, dead_temp} =
               Swap.prepare("/tmp/dead-temp.ex", "dead", swap_dir: tmp_dir, os_pid: dead_pid)

      assert {:ok, live_temp} =
               Swap.prepare("/tmp/live-temp.ex", "live", swap_dir: tmp_dir, os_pid: live_pid)

      arbitrary_temp = Path.join(tmp_dir, "notes.tmp")
      similar_temp = Path.join(tmp_dir, "not-a-swap.#{dead_pid}.swap.1.2.tmp")
      File.write!(arbitrary_temp, "leave me")
      File.write!(similar_temp, "leave me too")

      pid_alive? = fn os_pid -> os_pid == live_pid end
      assert Recovery.scan(scan_opts(tmp_dir, pid_alive?)) == []

      refute File.exists?(dead_temp.temporary_path)
      assert File.exists?(live_temp.temporary_path)
      assert File.exists?(arbitrary_temp)
      assert File.exists?(similar_temp)
    end

    test "logs failure to remove a recognized orphaned temporary file", %{tmp_dir: tmp_dir} do
      os_pid = 99_993
      target = Swap.swap_path("/tmp/removal-failure.ex", swap_dir: tmp_dir, os_pid: os_pid)
      temporary_path = "#{target}.1.123.tmp"
      File.mkdir_p!(temporary_path)
      assert {:error, reason} = File.rm(temporary_path)

      log =
        capture_log(fn ->
          assert Recovery.scan(scan_opts(tmp_dir, fn _pid -> false end)) == []
        end)

      assert log =~ "Failed to remove orphaned swap temporary file"
      assert log =~ temporary_path
      assert log =~ inspect(reason)
      assert File.dir?(temporary_path)
    end

    test "finds multiple recoverable swap files", %{tmp_dir: tmp_dir} do
      for i <- 1..3 do
        original = Path.join(tmp_dir, "file#{i}.ex")
        File.write!(original, "content #{i}")
        write_swap_file(tmp_dir, original, "modified #{i}", os_pid: 99_990 + i)
      end

      results = Recovery.scan(scan_opts(tmp_dir))
      assert Enum.count(results) == 3
    end
  end

  describe "recover/1" do
    test "returns file path and content, deletes swap file", %{tmp_dir: tmp_dir} do
      original = Path.join(tmp_dir, "recover_me.ex")
      File.write!(original, "original")

      swap_path = write_swap_file(tmp_dir, original, "unsaved changes")
      assert File.exists?(swap_path)

      assert {:ok, ^original, "unsaved changes"} = Recovery.recover(swap_path)
      refute File.exists?(swap_path)
    end

    test "returns error for corrupt swap file", %{tmp_dir: tmp_dir} do
      corrupt_path = Path.join(tmp_dir, "bad.swap")
      File.write!(corrupt_path, "not valid")

      assert {:error, :invalid_format} = Recovery.recover(corrupt_path)
    end
  end

  describe "discard/1" do
    test "deletes the swap file", %{tmp_dir: tmp_dir} do
      original = Path.join(tmp_dir, "discard_me.ex")
      swap_path = write_swap_file(tmp_dir, original, "content")
      assert File.exists?(swap_path)

      :ok = Recovery.discard(swap_path)
      refute File.exists?(swap_path)
    end
  end
end
