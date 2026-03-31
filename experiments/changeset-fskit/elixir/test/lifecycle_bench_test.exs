defmodule ChangesetFs.LifecycleBenchTest do
  use ExUnit.Case

  alias ChangesetFs.Protocol
  alias ChangesetFs.Server

  @moduledoc """
  Simulates a full LLM agent lifecycle on a 500-file Elixir project
  and compares three approaches:

  1. Direct filesystem (baseline) - what agents do today
  2. Hardlink overlay (experiments/changeset) - the 80% solution
  3. FSKit socket protocol - the macOS FUSE replacement

  The lifecycle models a real agent session:
  - Phase 1: Explore (read 30 files, grep 5 patterns)
  - Phase 2: Edit (modify 15 files, create 3 new files)
  - Phase 3: Compile check (read all 500+ files for compilation)
  - Phase 4: Fix (read 5 error files, edit 5 files)
  - Phase 5: Compile again
  - Phase 6: Test (read all files again + test files)
  - Phase 7: Fix test failures (read 3 files, edit 3 files)
  - Phase 8: Final compile + test
  - Phase 9: Discard or merge

  Total operations per lifecycle:
  - ~60 individual file reads (exploration + error reading)
  - ~26 file writes (edits)
  - ~5 grep operations (each reading ~500 files)
  - ~3 full compile simulations (each reading ~500 files)
  - ~2 full test simulations (each reading ~700 files)
  - Grand total: ~4,600 file read operations, ~26 writes
  """

  @file_count 500
  @test_file_count 200

  setup_all do
    project = create_project(@file_count, @test_file_count)
    on_exit(fn -> File.rm_rf!(project) end)
    %{project: project}
  end

  describe "lifecycle comparison" do
    test "full agent lifecycle: direct filesystem vs hardlink overlay vs FSKit socket", %{project: project} do
      IO.puts("\n")
      IO.puts("  ══════════════════════════════════════════════════════════════")
      IO.puts("  Agent Lifecycle Benchmark: #{@file_count} source + #{@test_file_count} test files")
      IO.puts("  ══════════════════════════════════════════════════════════════")

      # ── Baseline: Direct Filesystem ──────────────────────────────────
      IO.puts("\n  ── Direct Filesystem (baseline) ──")
      {fs_time, fs_ops} = bench_direct_filesystem(project)

      # ── Hardlink Overlay ─────────────────────────────────────────────
      IO.puts("\n  ── Hardlink Overlay ──")
      {hl_time, hl_ops} = bench_hardlink_overlay(project)

      # ── FSKit Socket Protocol ────────────────────────────────────────
      IO.puts("\n  ── FSKit Socket Protocol ──")
      {fsk_time, fsk_ops} = bench_fskit_socket(project)

      # ── Summary ──────────────────────────────────────────────────────
      IO.puts("\n  ══════════════════════════════════════════════════════════════")
      IO.puts("  TOTALS (wall clock, excluding overlay/server setup)")
      IO.puts("  ──────────────────────────────────────────────────────────────")
      IO.puts("  Direct filesystem:  #{fmt_ms(fs_time)} (#{fs_ops} ops)")
      IO.puts("  Hardlink overlay:   #{fmt_ms(hl_time)} (#{hl_ops} ops)")
      IO.puts("  FSKit socket:       #{fmt_ms(fsk_time)} (#{fsk_ops} ops)")
      IO.puts("  ──────────────────────────────────────────────────────────────")
      IO.puts("  Hardlink overhead:  #{fmt_ms(hl_time - fs_time)} (#{pct(hl_time, fs_time)})")
      IO.puts("  FSKit overhead:     #{fmt_ms(fsk_time - fs_time)} (#{pct(fsk_time, fs_time)})")
      IO.puts("  ══════════════════════════════════════════════════════════════")

      # ── Setup costs (amortized once per changeset) ───────────────────
      IO.puts("\n  One-time setup costs:")

      {hl_setup_us, _} = :timer.tc(fn ->
        overlay_dir = create_hardlink_overlay(project)
        File.rm_rf!(overlay_dir)
      end)
      IO.puts("  Hardlink overlay creation: #{fmt_ms(hl_setup_us)}")

      {fsk_setup_us, _} = :timer.tc(fn ->
        {:ok, srv} = Server.start_link(project_root: project)
        GenServer.stop(srv)
      end)
      IO.puts("  FSKit server startup:      #{fmt_ms(fsk_setup_us)}")

      IO.puts("")
    end
  end

  # ── Direct Filesystem Benchmark ──────────────────────────────────

  defp bench_direct_filesystem(project) do
    total_ops = 0

    # Phase 1: Explore (read 30 files)
    {t1, _} = :timer.tc(fn ->
      Enum.each(1..30, fn i ->
        File.read!(Path.join(project, "lib/group_#{rem(i, 20)}/module_#{i}.ex"))
      end)
    end)
    total_ops = total_ops + 30
    IO.puts("    Phase 1 (explore 30 files):       #{fmt_ms(t1)}")

    # Phase 1b: Grep 5 patterns (each reads ~500 files via shell)
    {t1b, _} = :timer.tc(fn ->
      Enum.each(1..5, fn i ->
        System.cmd("grep", ["-r", "Module#{i * 100}", "lib/"], cd: project, stderr_to_stdout: true)
      end)
    end)
    total_ops = total_ops + 5
    IO.puts("    Phase 1b (5 greps):               #{fmt_ms(t1b)}")

    # Phase 2: Edit 15 files + create 3 new
    {t2, _} = :timer.tc(fn ->
      Enum.each(1..15, fn i ->
        path = Path.join(project, "lib/group_#{rem(i, 20)}/module_#{i}.ex")
        content = File.read!(path)
        new_content = String.replace(content, "def value", "def updated_value")
        File.write!(path, new_content)
      end)

      Enum.each(1..3, fn i ->
        path = Path.join(project, "lib/new_module_#{i}.ex")
        File.write!(path, "defmodule NewModule#{i} do\n  def run, do: :ok\nend\n")
      end)
    end)
    total_ops = total_ops + 18 * 2  # read + write each
    IO.puts("    Phase 2 (edit 15 + create 3):     #{fmt_ms(t2)}")

    # Phase 3: Compile simulation (read all source files)
    {t3, _} = :timer.tc(fn -> read_all_source_files(project) end)
    total_ops = total_ops + @file_count + 3
    IO.puts("    Phase 3 (compile, #{@file_count + 3} reads):    #{fmt_ms(t3)}")

    # Phase 4: Fix 5 files
    {t4, _} = :timer.tc(fn ->
      Enum.each(16..20, fn i ->
        path = Path.join(project, "lib/group_#{rem(i, 20)}/module_#{i}.ex")
        content = File.read!(path)
        File.write!(path, content <> "\n  def fix_#{i}, do: :fixed\n")
      end)
    end)
    total_ops = total_ops + 10
    IO.puts("    Phase 4 (fix 5 files):            #{fmt_ms(t4)}")

    # Phase 5: Compile again
    {t5, _} = :timer.tc(fn -> read_all_source_files(project) end)
    total_ops = total_ops + @file_count + 3
    IO.puts("    Phase 5 (recompile):              #{fmt_ms(t5)}")

    # Phase 6: Test simulation (read all source + test files)
    {t6, _} = :timer.tc(fn ->
      read_all_source_files(project)
      read_all_test_files(project)
    end)
    total_ops = total_ops + @file_count + @test_file_count + 3
    IO.puts("    Phase 6 (test, #{@file_count + @test_file_count + 3} reads):     #{fmt_ms(t6)}")

    # Phase 7: Fix 3 test failures
    {t7, _} = :timer.tc(fn ->
      Enum.each(1..3, fn i ->
        path = Path.join(project, "test/group_#{rem(i, 10)}/module_#{i}_test.exs")
        content = File.read!(path)
        File.write!(path, content <> "\n  # fixed\n")
      end)
    end)
    total_ops = total_ops + 6
    IO.puts("    Phase 7 (fix 3 tests):            #{fmt_ms(t7)}")

    # Phase 8: Final compile + test
    {t8, _} = :timer.tc(fn ->
      read_all_source_files(project)
      read_all_test_files(project)
    end)
    total_ops = total_ops + @file_count + @test_file_count + 3
    IO.puts("    Phase 8 (final verify):           #{fmt_ms(t8)}")

    # Restore project for next benchmark
    restore_project(project)

    total = t1 + t1b + t2 + t3 + t4 + t5 + t6 + t7 + t8
    {total, total_ops}
  end

  # ── Hardlink Overlay Benchmark ───────────────────────────────────

  defp bench_hardlink_overlay(project) do
    overlay = create_hardlink_overlay(project)
    total_ops = 0

    # Phase 1: Explore
    {t1, _} = :timer.tc(fn ->
      Enum.each(1..30, fn i ->
        File.read!(Path.join(overlay, "lib/group_#{rem(i, 20)}/module_#{i}.ex"))
      end)
    end)
    total_ops = total_ops + 30
    IO.puts("    Phase 1 (explore 30 files):       #{fmt_ms(t1)}")

    # Phase 1b: Grep (runs in overlay dir)
    {t1b, _} = :timer.tc(fn ->
      Enum.each(1..5, fn i ->
        System.cmd("grep", ["-r", "Module#{i * 100}", "lib/"], cd: overlay, stderr_to_stdout: true)
      end)
    end)
    total_ops = total_ops + 5
    IO.puts("    Phase 1b (5 greps):               #{fmt_ms(t1b)}")

    # Phase 2: Edit (delete hardlink, write new content)
    {t2, _} = :timer.tc(fn ->
      Enum.each(1..15, fn i ->
        path = Path.join(overlay, "lib/group_#{rem(i, 20)}/module_#{i}.ex")
        content = File.read!(path)
        new_content = String.replace(content, "def value", "def updated_value")
        File.rm!(path)
        File.write!(path, new_content)
      end)

      Enum.each(1..3, fn i ->
        File.write!(Path.join(overlay, "lib/new_module_#{i}.ex"),
          "defmodule NewModule#{i} do\n  def run, do: :ok\nend\n")
      end)
    end)
    total_ops = total_ops + 36
    IO.puts("    Phase 2 (edit 15 + create 3):     #{fmt_ms(t2)}")

    # Phase 3-8: Same read patterns but from overlay
    {t3, _} = :timer.tc(fn -> read_all_source_files(overlay) end)
    total_ops = total_ops + @file_count + 3
    IO.puts("    Phase 3 (compile):                #{fmt_ms(t3)}")

    {t4, _} = :timer.tc(fn ->
      Enum.each(16..20, fn i ->
        path = Path.join(overlay, "lib/group_#{rem(i, 20)}/module_#{i}.ex")
        content = File.read!(path)
        File.rm!(path)
        File.write!(path, content <> "\n  def fix_#{i}, do: :fixed\n")
      end)
    end)
    total_ops = total_ops + 10
    IO.puts("    Phase 4 (fix 5 files):            #{fmt_ms(t4)}")

    {t5, _} = :timer.tc(fn -> read_all_source_files(overlay) end)
    total_ops = total_ops + @file_count + 3
    IO.puts("    Phase 5 (recompile):              #{fmt_ms(t5)}")

    {t6, _} = :timer.tc(fn ->
      read_all_source_files(overlay)
      read_all_test_files(overlay)
    end)
    total_ops = total_ops + @file_count + @test_file_count + 3
    IO.puts("    Phase 6 (test):                   #{fmt_ms(t6)}")

    {t7, _} = :timer.tc(fn ->
      Enum.each(1..3, fn i ->
        path = Path.join(overlay, "test/group_#{rem(i, 10)}/module_#{i}_test.exs")
        content = File.read!(path)
        File.rm!(path)
        File.write!(path, content <> "\n  # fixed\n")
      end)
    end)
    total_ops = total_ops + 6
    IO.puts("    Phase 7 (fix 3 tests):            #{fmt_ms(t7)}")

    {t8, _} = :timer.tc(fn ->
      read_all_source_files(overlay)
      read_all_test_files(overlay)
    end)
    total_ops = total_ops + @file_count + @test_file_count + 3
    IO.puts("    Phase 8 (final verify):           #{fmt_ms(t8)}")

    # Cleanup (measures discard cost)
    {t_cleanup, _} = :timer.tc(fn -> File.rm_rf!(overlay) end)
    IO.puts("    Discard (rm -rf overlay):         #{fmt_ms(t_cleanup)}")

    total = t1 + t1b + t2 + t3 + t4 + t5 + t6 + t7 + t8
    {total, total_ops}
  end

  # ── FSKit Socket Protocol Benchmark ──────────────────────────────

  defp bench_fskit_socket(project) do
    {:ok, server} = Server.start_link(project_root: project)
    socket_path = Server.socket_path(server)
    Process.sleep(50)

    {:ok, socket} = :gen_tcp.connect(
      {:local, String.to_charlist(socket_path)},
      0,
      [:binary, packet: 4, active: false]
    )

    total_ops = 0

    # Phase 1: Explore (30 reads via socket)
    {t1, _} = :timer.tc(fn ->
      Enum.each(1..30, fn i ->
        path = "lib/group_#{rem(i, 20)}/module_#{i}.ex"
        :gen_tcp.send(socket, Protocol.encode_read(path, 0, 999_999))
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      end)
    end)
    total_ops = total_ops + 30
    IO.puts("    Phase 1 (explore 30 files):       #{fmt_ms(t1)}")

    # Phase 1b: Grep simulation (readdir + read all files, 5 times)
    {t1b, _} = :timer.tc(fn ->
      Enum.each(1..5, fn _ ->
        # Read all source files through socket (simulates grep traversal)
        Enum.each(0..19, fn g ->
          :gen_tcp.send(socket, Protocol.encode_readdir("lib/group_#{g}"))
          {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
        end)

        Enum.each(1..@file_count, fn i ->
          path = "lib/group_#{rem(i, 20)}/module_#{i}.ex"
          :gen_tcp.send(socket, Protocol.encode_read(path, 0, 999_999))
          {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
        end)
      end)
    end)
    total_ops = total_ops + 5 * (@file_count + 20)
    IO.puts("    Phase 1b (5 greps via socket):    #{fmt_ms(t1b)}")

    # Phase 2: Edit 15 files + create 3
    {t2, _} = :timer.tc(fn ->
      Enum.each(1..15, fn i ->
        path = "lib/group_#{rem(i, 20)}/module_#{i}.ex"
        :gen_tcp.send(socket, Protocol.encode_read(path, 0, 999_999))
        {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
        {:ok, {:data, content}} = Protocol.decode_response(data)
        new_content = String.replace(content, "def value", "def updated_value")
        Server.update_file(server, path, new_content)
      end)

      Enum.each(1..3, fn i ->
        Server.update_file(server, "lib/new_module_#{i}.ex",
          "defmodule NewModule#{i} do\n  def run, do: :ok\nend\n")
      end)
    end)
    total_ops = total_ops + 33
    IO.puts("    Phase 2 (edit 15 + create 3):     #{fmt_ms(t2)}")

    # Phase 3: Compile simulation (read all files through socket)
    {t3, ops3} = bench_socket_compile(socket, @file_count + 3)
    total_ops = total_ops + ops3
    IO.puts("    Phase 3 (compile):                #{fmt_ms(t3)}")

    # Phase 4: Fix 5 files
    {t4, _} = :timer.tc(fn ->
      Enum.each(16..20, fn i ->
        path = "lib/group_#{rem(i, 20)}/module_#{i}.ex"
        :gen_tcp.send(socket, Protocol.encode_read(path, 0, 999_999))
        {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
        {:ok, {:data, content}} = Protocol.decode_response(data)
        Server.update_file(server, path, content <> "\n  def fix_#{i}, do: :fixed\n")
      end)
    end)
    total_ops = total_ops + 10
    IO.puts("    Phase 4 (fix 5 files):            #{fmt_ms(t4)}")

    # Phase 5: Recompile
    {t5, ops5} = bench_socket_compile(socket, @file_count + 3)
    total_ops = total_ops + ops5
    IO.puts("    Phase 5 (recompile):              #{fmt_ms(t5)}")

    # Phase 6: Test (compile + read test files)
    {t6, ops6} = bench_socket_test(socket, @file_count + 3, @test_file_count)
    total_ops = total_ops + ops6
    IO.puts("    Phase 6 (test):                   #{fmt_ms(t6)}")

    # Phase 7: Fix 3 tests
    {t7, _} = :timer.tc(fn ->
      Enum.each(1..3, fn i ->
        path = "test/group_#{rem(i, 10)}/module_#{i}_test.exs"
        :gen_tcp.send(socket, Protocol.encode_read(path, 0, 999_999))
        {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
        {:ok, {:data, content}} = Protocol.decode_response(data)
        Server.update_file(server, path, content <> "\n  # fixed\n")
      end)
    end)
    total_ops = total_ops + 6
    IO.puts("    Phase 7 (fix 3 tests):            #{fmt_ms(t7)}")

    # Phase 8: Final verify
    {t8, ops8} = bench_socket_test(socket, @file_count + 3, @test_file_count)
    total_ops = total_ops + ops8
    IO.puts("    Phase 8 (final verify):           #{fmt_ms(t8)}")

    :gen_tcp.close(socket)
    GenServer.stop(server)

    total = t1 + t1b + t2 + t3 + t4 + t5 + t6 + t7 + t8
    {total, total_ops}
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp bench_socket_compile(socket, file_count) do
    {time, _} = :timer.tc(fn ->
      Enum.each(0..19, fn g ->
        :gen_tcp.send(socket, Protocol.encode_readdir("lib/group_#{g}"))
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      end)

      Enum.each(1..file_count, fn i ->
        path = "lib/group_#{rem(i, 20)}/module_#{i}.ex"
        :gen_tcp.send(socket, Protocol.encode_read(path, 0, 999_999))
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      end)
    end)

    {time, file_count + 20}
  end

  defp bench_socket_test(socket, source_count, test_count) do
    {time, _} = :timer.tc(fn ->
      # Read source files
      Enum.each(1..source_count, fn i ->
        path = "lib/group_#{rem(i, 20)}/module_#{i}.ex"
        :gen_tcp.send(socket, Protocol.encode_read(path, 0, 999_999))
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      end)

      # Read test files
      Enum.each(1..test_count, fn i ->
        path = "test/group_#{rem(i, 10)}/module_#{i}_test.exs"
        :gen_tcp.send(socket, Protocol.encode_read(path, 0, 999_999))
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      end)
    end)

    {time, source_count + test_count}
  end

  defp read_all_source_files(root) do
    Enum.each(1..@file_count, fn i ->
      File.read!(Path.join(root, "lib/group_#{rem(i, 20)}/module_#{i}.ex"))
    end)

    # Also read new files if they exist
    Enum.each(1..3, fn i ->
      path = Path.join(root, "lib/new_module_#{i}.ex")
      if File.exists?(path), do: File.read!(path)
    end)
  end

  defp read_all_test_files(root) do
    Enum.each(1..@test_file_count, fn i ->
      File.read!(Path.join(root, "test/group_#{rem(i, 10)}/module_#{i}_test.exs"))
    end)
  end

  defp create_project(source_count, test_count) do
    project = Path.join(System.tmp_dir!(), "lifecycle-bench-#{System.unique_integer([:positive])}")

    Enum.each(1..source_count, fn i ->
      dir = Path.join(project, "lib/group_#{rem(i, 20)}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "module_#{i}.ex"), """
      defmodule Module#{i} do
        @moduledoc "Module number #{i}"
        def value, do: #{i}
        def name, do: "module_#{i}"
        def compute(x), do: x * #{i} + #{i * 2}
      end
      """)
    end)

    Enum.each(1..test_count, fn i ->
      dir = Path.join(project, "test/group_#{rem(i, 10)}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "module_#{i}_test.exs"), """
      defmodule Module#{i}Test do
        use ExUnit.Case
        test "value is #{i}" do
          assert Module#{i}.value() == #{i}
        end
        test "name is correct" do
          assert Module#{i}.name() == "module_#{i}"
        end
      end
      """)
    end)

    project
  end

  defp create_hardlink_overlay(project) do
    overlay = Path.join(System.tmp_dir!(), "hl-overlay-#{System.unique_integer([:positive])}")
    mirror_with_hardlinks(project, overlay)
    overlay
  end

  defp mirror_with_hardlinks(source, target) do
    File.mkdir_p!(target)

    case File.ls(source) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          s = Path.join(source, entry)
          t = Path.join(target, entry)

          cond do
            File.dir?(s) -> mirror_with_hardlinks(s, t)
            File.regular?(s) -> File.ln!(s, t)
            true -> :ok
          end
        end)

      _ -> :ok
    end
  end

  defp restore_project(project) do
    # Revert edits made during direct filesystem benchmark
    Enum.each(1..20, fn i ->
      path = Path.join(project, "lib/group_#{rem(i, 20)}/module_#{i}.ex")

      File.write!(path, """
      defmodule Module#{i} do
        @moduledoc "Module number #{i}"
        def value, do: #{i}
        def name, do: "module_#{i}"
        def compute(x), do: x * #{i} + #{i * 2}
      end
      """)
    end)

    Enum.each(1..3, fn i ->
      File.rm(Path.join(project, "lib/new_module_#{i}.ex"))
    end)

    Enum.each(1..3, fn i ->
      path = Path.join(project, "test/group_#{rem(i, 10)}/module_#{i}_test.exs")

      File.write!(path, """
      defmodule Module#{i}Test do
        use ExUnit.Case
        test "value is #{i}" do
          assert Module#{i}.value() == #{i}
        end
        test "name is correct" do
          assert Module#{i}.name() == "module_#{i}"
        end
      end
      """)
    end)
  end

  defp fmt_ms(microseconds) do
    ms = microseconds / 1000
    cond do
      ms < 1 -> "#{Float.round(ms, 2)}ms"
      ms < 100 -> "#{Float.round(ms, 1)}ms"
      true -> "#{round(ms)}ms"
    end
  end

  defp pct(actual, baseline) do
    if baseline > 0 do
      ratio = actual / baseline
      diff = (ratio - 1.0) * 100
      sign = if diff >= 0, do: "+", else: ""
      "#{sign}#{Float.round(diff, 1)}%"
    else
      "N/A"
    end
  end
end
