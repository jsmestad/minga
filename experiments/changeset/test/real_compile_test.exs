defmodule Changeset.RealCompileTest do
  use ExUnit.Case

  alias ChangesetFs.Protocol
  alias ChangesetFs.Server, as: FskitServer

  @moduledoc """
  Runs real `mix compile` and `mix test` through all three pipelines:

  1. Direct filesystem (baseline) - what agents do today
  2. Hardlink overlay via Changeset GenServer - the portable solution
  3. FSKit socket protocol - the macOS virtual filesystem approach

  Every path compiles and tests the same 50-module Elixir project.
  No simulated reads. The compiler and test runner do real work.

  For the FSKit path: since we can't mount FSKit from a test, we route
  all agent I/O through the socket server (measuring real protocol
  overhead), then materialize the results for compilation. The socket
  round-trip count is identical to what a mounted FSKit filesystem would
  experience.
  """

  @source_count 50
  @test_count 25

  setup_all do
    project = generate_mix_project()

    IO.puts("\n  Setting up: compiling #{@source_count}-module project...")
    {_, 0} = System.cmd("sh", ["-c", "cd #{project} && mix compile 2>&1"])
    {_, 0} = System.cmd("sh", ["-c", "cd #{project} && mix test 2>&1"])
    IO.puts("  Project ready: #{@source_count} modules, #{@test_count} tests\n")

    on_exit(fn -> File.rm_rf!(project) end)
    %{project: project}
  end

  test "three-way comparison: direct vs hardlink vs FSKit socket", %{project: project} do
    IO.puts("  ═══════════════════════════════════════════════════════════")
    IO.puts("  Real Compile: #{@source_count} modules, #{@test_count} tests")
    IO.puts("  All paths: edit 10 files → compile → test → verify")
    IO.puts("  ═══════════════════════════════════════════════════════════")

    # ── 1. Hardlink Changeset (first: doesn't touch real project) ──
    IO.puts("\n  ── 1. Hardlink Changeset (GenServer + overlay) ──")
    hl = run_hardlink_path(project)

    # ── 2. FSKit Socket Protocol ───────────────────────────────────
    IO.puts("\n  ── 2. FSKit Socket (GenServer + socket + materialized overlay) ──")
    fsk = run_fskit_path(project)

    # ── 3. Direct Filesystem (last: modifies real project) ─────────
    IO.puts("\n  ── 3. Direct Filesystem (baseline) ──")
    fs = run_direct_path(project)

    # ── Summary ────────────────────────────────────────────────────
    IO.puts("\n  ═══════════════════════════════════════════════════════════")
    IO.puts("  RESULTS")
    IO.puts("  ───────────────────────────────────────────────────────────")
    IO.puts("  Per-cycle cost (edit 10 files + incremental compile + test):")
    IO.puts("")
    IO.puts("                       Edit       Compile    Test       Total")
    IO.puts("    Direct FS:         #{pad(fmt(fs.t_edit))} #{pad(fmt(fs.t_compile))} #{pad(fmt(fs.t_test))} #{fmt(fs.t_cycle)}")
    IO.puts("    Hardlink:          #{pad(fmt(hl.t_edit))} #{pad(fmt(hl.t_compile))} #{pad(fmt(hl.t_test))} #{fmt(hl.t_cycle)}")
    IO.puts("    FSKit socket:      #{pad(fmt(fsk.t_edit))} #{pad(fmt(fsk.t_compile))} #{pad(fmt(fsk.t_test))} #{fmt(fsk.t_cycle)}")
    IO.puts("")
    IO.puts("  Overhead vs direct filesystem:")
    IO.puts("    Hardlink:          #{overhead(hl.t_cycle, fs.t_cycle)}")
    IO.puts("    FSKit socket:      #{overhead(fsk.t_cycle, fs.t_cycle)}")
    IO.puts("")
    IO.puts("  One-time setup (amortized per changeset):")
    IO.puts("    Hardlink overlay:  #{fmt(hl.t_setup)} create + #{fmt(hl.t_warm)} cold compile + #{fmt(hl.t_discard)} discard")
    IO.puts("    FSKit server:      #{fmt(fsk.t_setup)} create + #{fmt(fsk.t_warm)} cold compile + #{fmt(fsk.t_discard)} discard")
    IO.puts("    FSKit socket I/O:  #{fmt(fsk.t_socket_io)} (#{fsk.socket_ops} round-trips for overlay materialization)")
    IO.puts("")
    IO.puts("  Correctness:")
    IO.puts("    All paths compiled modified code:  #{fs.correct and hl.correct and fsk.correct}")
    IO.puts("    Project unchanged after both changesets: #{verify_project_clean(project)}")
    IO.puts("  ═══════════════════════════════════════════════════════════\n")

    assert hl.correct, "Hardlink should compile modified code"
    assert fsk.correct, "FSKit should compile modified code"
    assert fs.correct, "Direct FS should compile modified code"
    assert verify_project_clean(project), "Project should be clean after changeset runs"
  end

  # ── Direct Filesystem Path ──────────────────────────────────────

  defp run_direct_path(project) do
    originals = capture_originals(project)

    {t_edit, _} = :timer.tc(fn ->
      Enum.each(1..10, fn i ->
        path = Path.join(project, "lib/mod_#{i}.ex")
        content = File.read!(path)
        File.write!(path, make_edit(content, i))
      end)
    end)
    IO.puts("    Edit 10 files:          #{fmt(t_edit)}")

    {t_compile, {_, exit_c}} = :timer.tc(fn ->
      System.cmd("sh", ["-c", "cd #{project} && mix compile 2>&1"])
    end)
    IO.puts("    Incremental compile:    #{fmt(t_compile)}#{if exit_c != 0, do: " ⚠", else: ""}")

    {t_test, {test_out, _}} = :timer.tc(fn ->
      System.cmd("sh", ["-c", "cd #{project} && mix test 2>&1"])
    end)
    IO.puts("    Run tests:              #{fmt(t_test)} #{test_summary(test_out)}")

    {verify_out, _} = System.cmd("sh", ["-c",
      "cd #{project} && mix run -e 'IO.puts(Mod1.value())' 2>&1"])
    correct = String.trim(verify_out) =~ "1000"
    IO.puts("    Mod1.value():           #{String.trim(verify_out)}")

    restore_originals(originals)
    System.cmd("sh", ["-c", "cd #{project} && mix compile --force 2>&1"])

    %{t_edit: t_edit, t_compile: t_compile, t_test: t_test,
      t_cycle: t_edit + t_compile + t_test, correct: correct,
      t_setup: 0, t_warm: 0, t_discard: 0}
  end

  # ── Hardlink Changeset Path ─────────────────────────────────────

  defp run_hardlink_path(project) do
    {t_setup, {:ok, cs}} = :timer.tc(fn -> Changeset.create(project) end)
    IO.puts("    Create overlay:         #{fmt(t_setup)}")

    {t_warm, {_, warm_exit}} = :timer.tc(fn ->
      Changeset.run(cs, "mix compile 2>&1", timeout: 120_000)
    end)
    IO.puts("    Cold compile:           #{fmt(t_warm)}#{if warm_exit != 0, do: " ⚠", else: ""}")

    {t_edit, _} = :timer.tc(fn ->
      Enum.each(1..10, fn i ->
        {:ok, content} = Changeset.read_file(cs, "lib/mod_#{i}.ex")
        :ok = Changeset.write_file(cs, "lib/mod_#{i}.ex", make_edit(content, i))
      end)
    end)
    IO.puts("    Edit 10 files:          #{fmt(t_edit)}")

    {t_compile, {_, exit_c}} = :timer.tc(fn ->
      Changeset.run(cs, "mix compile 2>&1", timeout: 60_000)
    end)
    IO.puts("    Incremental compile:    #{fmt(t_compile)}#{if exit_c != 0, do: " ⚠", else: ""}")

    {t_test, {test_out, _}} = :timer.tc(fn ->
      Changeset.run(cs, "mix test 2>&1", timeout: 120_000)
    end)
    IO.puts("    Run tests:              #{fmt(t_test)} #{test_summary(test_out)}")

    {verify_out, _} = Changeset.run(cs,
      "mix run -e 'IO.puts(Mod1.value())' 2>&1", timeout: 30_000)
    correct = String.trim(verify_out) =~ "1000"
    IO.puts("    Mod1.value():           #{String.trim(verify_out)}")

    {t_discard, _} = :timer.tc(fn -> Changeset.discard(cs) end)
    IO.puts("    Discard:                #{fmt(t_discard)}")

    %{t_edit: t_edit, t_compile: t_compile, t_test: t_test,
      t_cycle: t_edit + t_compile + t_test, correct: correct,
      t_setup: t_setup, t_warm: t_warm, t_discard: t_discard}
  end

  # ── FSKit Socket Path ───────────────────────────────────────────
  #
  # Routes all agent I/O through the socket server (real protocol
  # overhead), then materializes the result as a hardlink overlay
  # for compilation. This measures the exact overhead FSKit would add:
  # one socket round-trip per file read/write during the edit phase.
  #
  # For compilation: the overlay directory is pre-populated via socket
  # reads (simulating what FSKit would do as the compiler opens each
  # file). The compiler then reads from the materialized directory.

  defp run_fskit_path(project) do
    # Start the socket server
    {t_server, {:ok, server}} = :timer.tc(fn ->
      FskitServer.start_link(project_root: project)
    end)
    socket_path = FskitServer.socket_path(server)
    Process.sleep(50)

    {:ok, socket} = :gen_tcp.connect(
      {:local, String.to_charlist(socket_path)},
      0, [:binary, packet: 4, active: false]
    )

    # Create hardlink overlay for compilation
    {t_overlay, overlay_dir} = :timer.tc(fn -> create_hardlink_overlay(project) end)
    t_setup = t_server + t_overlay
    IO.puts("    Setup (server + overlay): #{fmt(t_setup)}")

    # Warm overlay _build
    {t_warm, {_, warm_exit}} = :timer.tc(fn ->
      run_in_overlay(overlay_dir, project, "mix compile 2>&1", 120_000)
    end)
    IO.puts("    Cold compile:           #{fmt(t_warm)}#{if warm_exit != 0, do: " ⚠", else: ""}")

    # Edit files through the socket (real protocol overhead)
    {t_edit, _} = :timer.tc(fn ->
      Enum.each(1..10, fn i ->
        path = "lib/mod_#{i}.ex"

        # Read through socket
        :gen_tcp.send(socket, Protocol.encode_read(path, 0, 999_999))
        {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
        {:ok, {:data, content}} = Protocol.decode_response(data)

        new_content = make_edit(content, i)

        # Write to socket server (in-memory)
        FskitServer.update_file(server, path, new_content)

        # Materialize to overlay (what FSKit would do on the write path)
        overlay_file = Path.join(overlay_dir, path)
        File.rm!(overlay_file)
        File.write!(overlay_file, new_content)
      end)
    end)
    IO.puts("    Edit 10 files (socket):  #{fmt(t_edit)}")

    # Simulate FSKit serving the compile: read all source files through
    # the socket, write to overlay, then compile. This measures the
    # socket overhead that FSKit would add to each compiler file read.
    {t_socket_io, socket_ops} = :timer.tc(fn ->
      ops = materialize_from_socket(socket, server, overlay_dir, project)
      ops
    end)
    socket_ops_count = socket_ops
    IO.puts("    Socket I/O (materialize): #{fmt(t_socket_io)} (#{socket_ops_count} round-trips)")

    {t_compile, {_, exit_c}} = :timer.tc(fn ->
      run_in_overlay(overlay_dir, project, "mix compile 2>&1", 60_000)
    end)
    IO.puts("    Incremental compile:    #{fmt(t_compile)}#{if exit_c != 0, do: " ⚠", else: ""}")

    {t_test, {test_out, _}} = :timer.tc(fn ->
      run_in_overlay(overlay_dir, project, "mix test 2>&1", 120_000)
    end)
    IO.puts("    Run tests:              #{fmt(t_test)} #{test_summary(test_out)}")

    {verify_out, _} = run_in_overlay(overlay_dir, project,
      "mix run -e 'IO.puts(Mod1.value())' 2>&1", 30_000)
    correct = String.trim(verify_out) =~ "1000"
    IO.puts("    Mod1.value():           #{String.trim(verify_out)}")

    {t_discard, _} = :timer.tc(fn ->
      :gen_tcp.close(socket)
      GenServer.stop(server)
      File.rm_rf!(overlay_dir)
    end)
    IO.puts("    Discard:                #{fmt(t_discard)}")

    %{t_edit: t_edit, t_compile: t_compile, t_test: t_test,
      t_cycle: t_edit + t_socket_io + t_compile + t_test,
      correct: correct, t_setup: t_setup, t_warm: t_warm,
      t_discard: t_discard, t_socket_io: t_socket_io,
      socket_ops: socket_ops_count}
  end

  # Read all modified files from the socket server and write them to
  # the overlay directory. Returns the number of socket round-trips.
  defp materialize_from_socket(socket, _server, overlay_dir, project) do
    # Get list of all source + test files
    source_files = Enum.map(1..@source_count, fn i -> "lib/mod_#{i}.ex" end)
    test_files = Enum.map(1..@test_count, fn i -> "test/mod_#{i}_test.exs" end)
    all_files = source_files ++ test_files

    # Read each through the socket and update overlay if content differs
    ops = Enum.reduce(all_files, 0, fn path, count ->
      :gen_tcp.send(socket, Protocol.encode_read(path, 0, 999_999))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:data, content}} = Protocol.decode_response(data)

      overlay_file = Path.join(overlay_dir, path)
      # Only rewrite if content differs from what's on disk
      current = File.read!(overlay_file)
      if current != content do
        File.rm!(overlay_file)
        File.write!(overlay_file, content)
      end

      count + 1
    end)

    ops
  end

  # ── Overlay Helpers ─────────────────────────────────────────────

  defp create_hardlink_overlay(project) do
    overlay = Path.join(System.tmp_dir!(), "fsk-overlay-#{System.unique_integer([:positive])}")
    mirror_hardlinks(project, overlay)
    overlay
  end

  defp mirror_hardlinks(source, target) do
    File.mkdir_p!(target)
    skip = MapSet.new(~w(_build deps .git .elixir_ls node_modules .hex))

    case File.ls(source) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          s = Path.join(source, entry)
          t = Path.join(target, entry)

          cond do
            MapSet.member?(skip, entry) -> :ok
            entry == "deps" and File.dir?(s) -> File.ln_s!(s, t)
            File.dir?(s) -> mirror_hardlinks(s, t)
            File.regular?(s) -> File.ln!(s, t)
            true -> :ok
          end
        end)
      _ -> :ok
    end
  end

  defp run_in_overlay(overlay_dir, project, command, timeout) do
    build_path = Path.join(overlay_dir, "_build")
    deps_path = Path.join(project, "deps")

    env = [
      {~c"MIX_BUILD_PATH", String.to_charlist(build_path)},
      {~c"MIX_DEPS_PATH", String.to_charlist(deps_path)},
      {~c"TERM", ~c"dumb"}
    ]

    port = Port.open(
      {:spawn_executable, ~c"/bin/sh"},
      [:binary, :exit_status, :stderr_to_stdout,
       args: ["-c", command], cd: overlay_dir, env: env]
    )

    collect_output(port, [], timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} -> collect_output(port, [data | acc], timeout)
      {^port, {:exit_status, code}} ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), code}
    after
      timeout ->
        Port.close(port)
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {output <> "\n[timeout]", 1}
    end
  end

  # ── Project Generation ──────────────────────────────────────────

  defp generate_mix_project do
    project = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(Path.join(project, "test"))

    File.write!(Path.join(project, "mix.exs"), """
    defmodule Bench.MixProject do
      use Mix.Project
      def project, do: [app: :bench, version: "0.1.0", elixir: "~> 1.17", deps: []]
      def application, do: [extra_applications: [:logger]]
    end
    """)

    File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")

    Enum.each(1..@source_count, fn i ->
      File.write!(Path.join(project, "lib/mod_#{i}.ex"), source_module(i))
    end)

    Enum.each(1..@test_count, fn i ->
      File.write!(Path.join(project, "test/mod_#{i}_test.exs"), test_module(i))
    end)

    project
  end

  defp source_module(i) do
    """
    defmodule Mod#{i} do
      @moduledoc "Module #{i}"
      def value, do: #{i}
      def name, do: "mod_#{i}"
      def compute(x) when is_number(x), do: x * #{i} + #{i * 2}
      def describe, do: "Module #{i}: value=\#{value()}, name=\#{name()}"
    end
    """
  end

  defp test_module(i) do
    """
    defmodule Mod#{i}Test do
      use ExUnit.Case, async: true
      test "value" do
        assert Mod#{i}.value() == #{i}
      end
      test "compute" do
        assert Mod#{i}.compute(10) == 10 * #{i} + #{i * 2}
      end
    end
    """
  end

  defp make_edit(content, i) do
    String.replace(content, "def value, do: #{i}", "def value, do: #{i * 1000}")
  end

  defp capture_originals(project) do
    Enum.map(1..10, fn i ->
      path = Path.join(project, "lib/mod_#{i}.ex")
      {path, File.read!(path)}
    end)
  end

  defp restore_originals(originals) do
    Enum.each(originals, fn {path, content} -> File.write!(path, content) end)
  end

  defp verify_project_clean(project) do
    content = File.read!(Path.join(project, "lib/mod_1.ex"))
    content =~ "def value, do: 1" and not (content =~ "1000")
  end

  defp test_summary(output) do
    cond do
      output =~ ~r/\d+ tests?, 0 failures/ ->
        Regex.run(~r/\d+ tests?, 0 failures/, output) |> List.first()
      output =~ ~r/\d+ tests?/ ->
        "(some failures expected)"
      true ->
        ""
    end
  end

  defp fmt(us) do
    ms = us / 1000
    cond do
      ms < 1 -> "#{Float.round(ms, 2)}ms"
      ms < 10 -> "#{Float.round(ms, 1)}ms"
      ms < 1000 -> "#{round(ms)}ms"
      true -> "#{Float.round(ms / 1000, 2)}s"
    end
  end

  defp pad(s), do: String.pad_trailing(s, 11)

  defp overhead(actual, baseline) do
    diff = actual - baseline
    pct = if baseline > 0, do: Float.round(diff / baseline * 100, 1), else: 0
    sign = if diff >= 0, do: "+", else: ""
    "#{sign}#{fmt(diff)} (#{sign}#{pct}%)"
  end
end
