defmodule Minga.ReleaseTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @native_artifacts ~w(minga-renderer-go minga-parser minga-hook-runner)
  @resources ~w(queries/elixir/highlights.scm extensions/example/extension.ex tree_sitter/parser.h tutor.txt)

  setup %{tmp_dir: external_dir} do
    dir = Path.join([Mix.Project.build_path(), "release-tests", Path.basename(external_dir)])
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp_dir: dir, external_dir: external_dir}
  end

  for name <- [:minga, :minga_macos] do
    @release_name name

    test "#{name} refuses shared output paths without deleting their contents", %{
      external_dir: dir
    } do
      release = %{release(@release_name, dir) | path: dir}
      files = Enum.map(~w(bin/tool lib/other-1.0/data), &write_file(dir, &1))
      [clean | _] = steps(@release_name)

      assert_raise Mix.Error, ~r/Release output must be inside/, fn -> clean.(release) end
      for file <- files, do: assert(File.read!(file) == "runtime asset")
    end

    test "#{name} starts assembly without previous runtime or application versions", %{
      tmp_dir: dir
    } do
      release = release(@release_name, dir)

      stale =
        ~w(erts-old/bin/beam.smp lib/minga-old/priv/minga-parser lib/removed-1/ebin/old.beam releases/old/start.boot)

      Enum.each(stale, &write_file(release.path, &1))
      source = write_file(dir, "source/priv/minga-test-harness")
      unrelated = write_file(release.path, "notes.txt")

      @release_name
      |> steps()
      |> Enum.take_while(&(&1 != :assemble))
      |> Enum.reduce(release, fn step, release -> step.(release) end)

      for path <- stale, do: refute(File.exists?(Path.join(release.path, path)))
      assert File.read!(source) == "runtime asset"
      assert File.read!(unrelated) == "runtime asset"
    end

    test "#{name} ships runtime assets without development leftovers", %{tmp_dir: dir} do
      release = release(@release_name, dir)
      priv = Path.join(release.path, "lib/minga-1.0.0/priv")
      Enum.each(@native_artifacts ++ @resources, &write_file(priv, &1))

      leftovers =
        ~w(minga-test-harness minga-renderer minga-renderer-gui scratch/output.dSYM/Contents/debug)

      Enum.each(leftovers, &write_file(priv, &1))

      assert after_assemble(@release_name).(release) == release

      for path <- @native_artifacts ++ @resources do
        assert File.read!(Path.join(priv, path)) == "runtime asset"
      end

      for path <- leftovers, do: refute(File.exists?(Path.join(priv, path)))
    end

    test "#{name} rejects missing current native artifacts even when an old version has them", %{
      tmp_dir: dir
    } do
      release = release(@release_name, dir)
      current_priv = Path.join(release.path, "lib/minga-1.0.0/priv")
      old_priv = Path.join(release.path, "lib/minga-0.9.0/priv")
      Enum.each(@native_artifacts, &write_file(old_priv, &1))
      Enum.each(@native_artifacts -- ["minga-parser"], &write_file(current_priv, &1))

      assert_raise Mix.Error, ~r/Missing native release artifacts: minga-parser/, fn ->
        after_assemble(@release_name).(release)
      end
    end
  end

  defp release(name, dir) do
    %Mix.Release{
      name: name,
      path: Path.join([dir, "[release]", Atom.to_string(name)]),
      version: "1.0.0",
      applications: %{minga: [vsn: ~c"1.0.0"]}
    }
  end

  defp steps(name), do: Minga.MixProject.project()[:releases][name][:steps]

  defp after_assemble(name) do
    [_assemble, step | _] = Enum.drop_while(steps(name), &(&1 != :assemble))
    step
  end

  defp write_file(root, path) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "runtime asset")
    path
  end
end
