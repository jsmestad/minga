defmodule Changeset.OptimizedTest do
  use ExUnit.Case

  alias Changeset.FastOverlay

  @moduledoc """
  Compares all approaches with the APFS clone + warm _build optimization.

  The key insight: every `mix compile` invocation pays ~250ms just to
  start the BEAM VM. The actual compilation of 10 changed files is ~30ms.
  The APFS clone eliminates the cold compile, and `_build` sharing means
  incremental compilation works immediately.
  """

  @source_count 50
  @test_count 25

  setup_all do
    project = generate_mix_project()
    IO.puts("\n  Compiling #{@source_count}-module project...")
    {_, 0} = System.cmd("sh", ["-c", "cd #{project} && mix compile 2>&1"])
    {_, 0} = System.cmd("sh", ["-c", "cd #{project} && mix test 2>&1"])
    IO.puts("  Ready.\n")
    on_exit(fn -> File.rm_rf!(project) end)
    %{project: project}
  end

  test "optimized comparison: all approaches", %{project: project} do
    IO.puts("  ═══════════════════════════════════════════════════════════")
    IO.puts("  Optimized Benchmark: #{@source_count} modules, #{@test_count} tests")
    IO.puts("  ═══════════════════════════════════════════════════════════")

    # ── 1. Baseline: Direct Filesystem ──
    IO.puts("\n  ── 1. Direct Filesystem (baseline) ──")
    fs = run_direct(project)

    # ── 2. Hardlink Overlay (original approach) ──
    IO.puts("\n  ── 2. Hardlink Overlay (original, cold _build) ──")
    hl = run_hardlink(project)

    # ── 3. APFS Clone (warm _build, no cold compile) ──
    IO.puts("\n  ── 3. APFS Clone (warm _build) ──")
    apfs = run_apfs_clone(project)

    # ── Summary ──
    IO.puts("\n  ═══════════════════════════════════════════════════════════")
    IO.puts("  RESULTS")
    IO.puts("  ───────────────────────────────────────────────────────────")
    IO.puts("")
    IO.puts("  Setup (one-time per changeset):")
    IO.puts("    Direct FS:        0ms")
    IO.puts("    Hardlink:         #{fmt(hl.t_create)} create + #{fmt(hl.t_cold)} cold compile")
    IO.puts("    APFS Clone:       #{fmt(apfs.t_create)} create (no cold compile needed)")
    IO.puts("")
    IO.puts("  Per-cycle (edit 10 → compile → test):")
    IO.puts("")
    IO.puts("                       Edit       Compile    Test       Total")
    IO.puts("    Direct FS:         #{pad(fmt(fs.t_edit))} #{pad(fmt(fs.t_compile))} #{pad(fmt(fs.t_test))} #{fmt(fs.t_cycle)}")
    IO.puts("    Hardlink:          #{pad(fmt(hl.t_edit))} #{pad(fmt(hl.t_compile))} #{pad(fmt(hl.t_test))} #{fmt(hl.t_cycle)}")
    IO.puts("    APFS Clone:        #{pad(fmt(apfs.t_edit))} #{pad(fmt(apfs.t_compile))} #{pad(fmt(apfs.t_test))} #{fmt(apfs.t_cycle)}")
    IO.puts("")
    IO.puts("  Overhead vs direct:")
    IO.puts("    Hardlink:          #{overhead(hl.t_cycle, fs.t_cycle)}")
    IO.puts("    APFS Clone:        #{overhead(apfs.t_cycle, fs.t_cycle)}")
    IO.puts("")
    IO.puts("  Total wall clock (setup + 1 cycle + discard):")
    IO.puts("    Direct FS:         #{fmt(fs.t_total)}")
    IO.puts("    Hardlink:          #{fmt(hl.t_total)}")
    IO.puts("    APFS Clone:        #{fmt(apfs.t_total)}")
    IO.puts("")
    IO.puts("  Correctness:         #{fs.correct and hl.correct and apfs.correct}")
    IO.puts("  Project clean:       #{verify_clean(project)}")
    IO.puts("  ═══════════════════════════════════════════════════════════\n")

    assert fs.correct and hl.correct and apfs.correct
    assert verify_clean(project)
  end

  # ── Direct Filesystem ───────────────────────────────────────────

  defp run_direct(project) do
    originals = save_originals(project)

    {t_edit, _} = :timer.tc(fn -> edit_files_direct(project) end)
    IO.puts("    Edit:     #{fmt(t_edit)}")

    {t_compile, _} = :timer.tc(fn ->
      System.cmd("sh", ["-c", "cd #{project} && mix compile 2>&1"])
    end)
    IO.puts("    Compile:  #{fmt(t_compile)}")

    {t_test, {out, _}} = :timer.tc(fn ->
      System.cmd("sh", ["-c", "cd #{project} && mix test 2>&1"])
    end)
    IO.puts("    Test:     #{fmt(t_test)} #{test_summary(out)}")

    correct = verify_value(project)
    IO.puts("    Correct:  #{correct}")

    restore_originals(originals)
    System.cmd("sh", ["-c", "cd #{project} && mix compile --force 2>&1"])

    %{t_edit: t_edit, t_compile: t_compile, t_test: t_test,
      t_cycle: t_edit + t_compile + t_test,
      t_total: t_edit + t_compile + t_test,
      t_create: 0, t_cold: 0, correct: correct}
  end

  # ── Hardlink Overlay (original approach with cold compile) ──────

  defp run_hardlink(project) do
    {t_create, {:ok, cs}} = :timer.tc(fn -> Changeset.create(project) end)
    IO.puts("    Create:   #{fmt(t_create)}")

    {t_cold, _} = :timer.tc(fn ->
      Changeset.run(cs, "mix compile 2>&1", timeout: 120_000)
    end)
    IO.puts("    Cold:     #{fmt(t_cold)}")

    {t_edit, _} = :timer.tc(fn -> edit_files_changeset(cs) end)
    IO.puts("    Edit:     #{fmt(t_edit)}")

    {t_compile, _} = :timer.tc(fn ->
      Changeset.run(cs, "mix compile 2>&1", timeout: 60_000)
    end)
    IO.puts("    Compile:  #{fmt(t_compile)}")

    {t_test, {out, _}} = :timer.tc(fn ->
      Changeset.run(cs, "mix test 2>&1", timeout: 120_000)
    end)
    IO.puts("    Test:     #{fmt(t_test)} #{test_summary(out)}")

    correct = verify_value_changeset(cs)
    IO.puts("    Correct:  #{correct}")

    {t_discard, _} = :timer.tc(fn -> Changeset.discard(cs) end)

    %{t_edit: t_edit, t_compile: t_compile, t_test: t_test,
      t_cycle: t_edit + t_compile + t_test,
      t_total: t_create + t_cold + t_edit + t_compile + t_test + t_discard,
      t_create: t_create, t_cold: t_cold, correct: correct}
  end

  # ── APFS Clone (warm _build, no cold compile) ──────────────────

  defp run_apfs_clone(project) do
    {t_create, {:ok, overlay}} = :timer.tc(fn -> FastOverlay.create(project) end)
    IO.puts("    Create:   #{fmt(t_create)}")

    # No cold compile needed! _build is already warm from the clone.

    {t_edit, _} = :timer.tc(fn ->
      Enum.each(1..10, fn i ->
        {:ok, content} = FastOverlay.read_file(overlay, "lib/mod_#{i}.ex")
        new_content = String.replace(content, "def value, do: #{i}", "def value, do: #{i * 1000}")
        FastOverlay.write_file(overlay, "lib/mod_#{i}.ex", new_content)
      end)
    end)
    IO.puts("    Edit:     #{fmt(t_edit)}")

    {t_compile, {out, exit}} = :timer.tc(fn ->
      FastOverlay.shell(overlay, "mix compile 2>&1", timeout: 60_000)
    end)
    IO.puts("    Compile:  #{fmt(t_compile)}#{if exit != 0, do: " ⚠ #{String.slice(out, 0, 100)}", else: ""}")

    {t_test, {test_out, _}} = :timer.tc(fn ->
      FastOverlay.shell(overlay, "mix test 2>&1", timeout: 120_000)
    end)
    IO.puts("    Test:     #{fmt(t_test)} #{test_summary(test_out)}")

    {verify_out, _} = FastOverlay.shell(overlay,
      "mix run -e 'IO.puts(Mod1.value())' 2>&1", timeout: 30_000)
    correct = String.trim(verify_out) =~ "1000"
    IO.puts("    Correct:  #{correct}")

    {t_discard, _} = :timer.tc(fn -> FastOverlay.cleanup(overlay) end)

    %{t_edit: t_edit, t_compile: t_compile, t_test: t_test,
      t_cycle: t_edit + t_compile + t_test,
      t_total: t_create + t_edit + t_compile + t_test + t_discard,
      t_create: t_create, t_cold: 0, correct: correct}
  end

  # ── Shared helpers ──────────────────────────────────────────────

  defp edit_files_direct(project) do
    Enum.each(1..10, fn i ->
      path = Path.join(project, "lib/mod_#{i}.ex")
      content = File.read!(path)
      File.write!(path, String.replace(content, "def value, do: #{i}", "def value, do: #{i * 1000}"))
    end)
  end

  defp edit_files_changeset(cs) do
    Enum.each(1..10, fn i ->
      {:ok, content} = Changeset.read_file(cs, "lib/mod_#{i}.ex")
      :ok = Changeset.write_file(cs, "lib/mod_#{i}.ex",
        String.replace(content, "def value, do: #{i}", "def value, do: #{i * 1000}"))
    end)
  end

  defp verify_value(project) do
    {out, _} = System.cmd("sh", ["-c",
      "cd #{project} && mix run -e 'IO.puts(Mod1.value())' 2>&1"])
    String.trim(out) =~ "1000"
  end

  defp verify_value_changeset(cs) do
    {out, _} = Changeset.run(cs, "mix run -e 'IO.puts(Mod1.value())' 2>&1", timeout: 30_000)
    String.trim(out) =~ "1000"
  end

  defp verify_clean(project) do
    content = File.read!(Path.join(project, "lib/mod_1.ex"))
    content =~ "def value, do: 1" and not (content =~ "1000")
  end

  defp save_originals(project) do
    Enum.map(1..10, fn i ->
      path = Path.join(project, "lib/mod_#{i}.ex")
      {path, File.read!(path)}
    end)
  end

  defp restore_originals(originals) do
    Enum.each(originals, fn {p, c} -> File.write!(p, c) end)
  end

  defp generate_mix_project do
    project = Path.join(System.tmp_dir!(), "optbench-#{System.unique_integer([:positive])}")
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
      File.write!(Path.join(project, "lib/mod_#{i}.ex"), """
      defmodule Mod#{i} do
        @moduledoc "Module #{i}"
        def value, do: #{i}
        def name, do: "mod_#{i}"
        def compute(x) when is_number(x), do: x * #{i} + #{i * 2}
        def describe, do: "Module #{i}: value=\#{value()}, name=\#{name()}"
      end
      """)
    end)

    Enum.each(1..@test_count, fn i ->
      File.write!(Path.join(project, "test/mod_#{i}_test.exs"), """
      defmodule Mod#{i}Test do
        use ExUnit.Case, async: true
        test "value" do
          assert Mod#{i}.value() == #{i}
        end
        test "compute" do
          assert Mod#{i}.compute(10) == 10 * #{i} + #{i * 2}
        end
      end
      """)
    end)

    project
  end

  defp test_summary(output) do
    case Regex.run(~r/\d+ tests?, \d+ failures?/, output) do
      [match] -> match
      _ -> "(ran)"
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
