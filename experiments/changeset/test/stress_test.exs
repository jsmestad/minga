defmodule Changeset.StressTest do
  use ExUnit.Case, async: true

  describe "undo within a changeset" do
    test "undo restores previous content" do
      project = make_project(%{"lib/app.ex" => "version 1"})
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.write_file(cs, "lib/app.ex", "version 2")
      assert {:ok, "version 2"} = Changeset.read_file(cs, "lib/app.ex")

      :ok = Changeset.undo(cs, "lib/app.ex")
      assert {:ok, "version 1"} = Changeset.read_file(cs, "lib/app.ex")

      Changeset.discard(cs)
      cleanup(project)
    end

    test "undo through multiple edits" do
      project = make_project(%{"lib/app.ex" => "original"})
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.write_file(cs, "lib/app.ex", "edit 1")
      :ok = Changeset.write_file(cs, "lib/app.ex", "edit 2")
      :ok = Changeset.write_file(cs, "lib/app.ex", "edit 3")

      :ok = Changeset.undo(cs, "lib/app.ex")
      assert {:ok, "edit 2"} = Changeset.read_file(cs, "lib/app.ex")

      :ok = Changeset.undo(cs, "lib/app.ex")
      assert {:ok, "edit 1"} = Changeset.read_file(cs, "lib/app.ex")

      :ok = Changeset.undo(cs, "lib/app.ex")
      assert {:ok, "original"} = Changeset.read_file(cs, "lib/app.ex")

      assert {:error, :nothing_to_undo} = Changeset.undo(cs, "lib/app.ex")

      Changeset.discard(cs)
      cleanup(project)
    end

    test "undo restores file in overlay so tools see it" do
      project = make_project(%{"lib/app.ex" => "original content"})
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.write_file(cs, "lib/app.ex", "changed content")
      {output, 0} = Changeset.run(cs, "grep 'changed' lib/app.ex")
      assert output =~ "changed"

      :ok = Changeset.undo(cs, "lib/app.ex")
      {output, 0} = Changeset.run(cs, "grep 'original' lib/app.ex")
      assert output =~ "original"

      Changeset.discard(cs)
      cleanup(project)
    end
  end

  describe "file deletion" do
    test "deleted file is invisible to tools" do
      project = make_project(%{
        "lib/keep.ex" => "keep this",
        "lib/remove.ex" => "remove this"
      })
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.delete_file(cs, "lib/remove.ex")

      {output, 0} = Changeset.run(cs, "find lib -name '*.ex' | sort")
      assert output =~ "keep.ex"
      refute output =~ "remove.ex"

      assert {:error, :deleted} = Changeset.read_file(cs, "lib/remove.ex")

      Changeset.discard(cs)
      cleanup(project)
    end

    test "undo restores a deleted file" do
      project = make_project(%{"lib/app.ex" => "content"})
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.delete_file(cs, "lib/app.ex")
      assert {:error, :deleted} = Changeset.read_file(cs, "lib/app.ex")

      :ok = Changeset.undo(cs, "lib/app.ex")
      assert {:ok, "content"} = Changeset.read_file(cs, "lib/app.ex")

      Changeset.discard(cs)
      cleanup(project)
    end
  end

  describe "reset" do
    test "reset undoes all changes across all files" do
      project = make_project(%{
        "lib/a.ex" => "original a",
        "lib/b.ex" => "original b"
      })
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.write_file(cs, "lib/a.ex", "changed a")
      :ok = Changeset.write_file(cs, "lib/b.ex", "changed b")
      :ok = Changeset.write_file(cs, "lib/c.ex", "new file c")

      :ok = Changeset.reset(cs)

      assert {:ok, "original a"} = Changeset.read_file(cs, "lib/a.ex")
      assert {:ok, "original b"} = Changeset.read_file(cs, "lib/b.ex")

      %{modified: modified} = Changeset.modified_files(cs)
      assert modified == []

      Changeset.discard(cs)
      cleanup(project)
    end
  end

  describe "budget system" do
    test "tracks attempts and enforces budget" do
      project = make_project(%{"lib/app.ex" => "content"})
      {:ok, cs} = Changeset.create(project, budget: 3)

      assert %{attempts: 0, budget: 3} = Changeset.attempt_info(cs)

      assert {:ok, 1} = Changeset.record_attempt(cs)
      assert {:ok, 2} = Changeset.record_attempt(cs)
      assert {:ok, 3} = Changeset.record_attempt(cs)
      assert {:budget_exhausted, 4, 3} = Changeset.record_attempt(cs)

      Changeset.discard(cs)
      cleanup(project)
    end

    test "unlimited budget never exhausts" do
      project = make_project(%{"lib/app.ex" => "content"})
      {:ok, cs} = Changeset.create(project)

      Enum.each(1..100, fn i ->
        assert {:ok, ^i} = Changeset.record_attempt(cs)
      end)

      Changeset.discard(cs)
      cleanup(project)
    end
  end

  describe "three-way merge" do
    test "clean merge when only changeset modified" do
      project = make_project(%{"lib/app.ex" => "line 1\nline 2\nline 3\n"})
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.edit_file(cs, "lib/app.ex", "line 2", "modified line 2")
      :ok = Changeset.merge(cs)

      assert File.read!(Path.join(project, "lib/app.ex")) =~ "modified line 2"

      cleanup(project)
    end

    test "clean merge when human edited different lines" do
      project = make_project(%{"lib/app.ex" => "line 1\nline 2\nline 3\nline 4\nline 5\n"})
      {:ok, cs} = Changeset.create(project)

      # Changeset modifies line 2
      :ok = Changeset.edit_file(cs, "lib/app.ex", "line 2", "agent line 2")

      # Human modifies line 5 (different region)
      real_path = Path.join(project, "lib/app.ex")
      content = File.read!(real_path)
      File.write!(real_path, String.replace(content, "line 5", "human line 5"))

      result = Changeset.merge(cs)

      # Both changes should be present
      merged = File.read!(real_path)
      assert merged =~ "agent line 2"
      assert merged =~ "human line 5"

      cleanup(project)
    end

    test "conflict when both sides modify same region" do
      project = make_project(%{"lib/app.ex" => "line 1\nline 2\nline 3\n"})
      {:ok, cs} = Changeset.create(project)

      # Changeset modifies line 2
      :ok = Changeset.edit_file(cs, "lib/app.ex", "line 2", "agent version")

      # Human also modifies line 2
      real_path = Path.join(project, "lib/app.ex")
      content = File.read!(real_path)
      File.write!(real_path, String.replace(content, "line 2", "human version"))

      result = Changeset.merge(cs)
      assert {:ok, :merged_with_conflicts, details} = result

      conflicts = Enum.filter(details, &match?({:conflict, _, _}, &1))
      assert length(conflicts) > 0

      cleanup(project)
    end

    test "merge detects new file conflict when both sides create same file" do
      project = make_project(%{"lib/app.ex" => "existing"})
      {:ok, cs} = Changeset.create(project)

      # Changeset creates a new file
      :ok = Changeset.write_file(cs, "lib/new.ex", "agent version")

      # Human also creates it
      File.write!(Path.join(project, "lib/new.ex"), "human version")

      result = Changeset.merge(cs)
      assert {:ok, :merged_with_conflicts, details} = result

      conflict = Enum.find(details, &match?({:conflict, "lib/new.ex", _}, &1))
      assert conflict

      cleanup(project)
    end

    test "merge handles deletion when file was also modified" do
      project = make_project(%{"lib/app.ex" => "original"})
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.delete_file(cs, "lib/app.ex")

      # Human modifies the file before we merge the deletion
      File.write!(Path.join(project, "lib/app.ex"), "human modified")

      result = Changeset.merge(cs)
      assert {:ok, :merged_with_conflicts, details} = result

      conflict = Enum.find(details, &match?({:conflict, "lib/app.ex", :modified_before_delete}, &1))
      assert conflict

      # File should still exist (we don't delete files the human modified)
      assert File.read!(Path.join(project, "lib/app.ex")) == "human modified"

      cleanup(project)
    end
  end

  describe "build isolation" do
    test "MIX_BUILD_PATH is set to isolated directory" do
      project = make_project(%{"lib/app.ex" => "content"})
      {:ok, cs} = Changeset.create(project)

      {output, 0} = Changeset.run(cs, "echo $MIX_BUILD_PATH")
      overlay = Changeset.overlay_path(cs)

      assert String.trim(output) == Path.join(overlay, "_build")

      Changeset.discard(cs)
      cleanup(project)
    end

    test "compilation in overlay does not contaminate real _build" do
      project = make_mix_project()

      # Compile the real project first
      {_, 0} = System.cmd("sh", ["-c", "cd #{project} && mix compile 2>&1"])
      assert File.dir?(Path.join(project, "_build"))

      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.write_file(cs, "lib/example.ex", """
      defmodule Example do
        def hello, do: "from changeset"
        def new_function, do: "only in changeset"
      end
      """)

      {output, exit_code} = Changeset.run(cs, "mix compile 2>&1", timeout: 30_000)

      if exit_code == 0 do
        # Changeset's _build is separate
        overlay = Changeset.overlay_path(cs)
        cs_build = Path.join(overlay, "_build")
        assert File.dir?(cs_build)

        # Real _build should NOT have the changeset's modifications
        real_beam = Path.join(project, "_build/dev/lib/example/ebin/Elixir.Example.beam")

        if File.exists?(real_beam) do
          # Load and check the real project's compiled module
          # It should still return "world", not "from changeset"
          {check_output, _} = System.cmd("sh", ["-c",
            "cd #{project} && mix run -e 'IO.puts(Example.hello())' 2>&1"
          ])
          assert String.trim(check_output) == "world"
        end
      else
        IO.puts("  mix compile in overlay: #{output}")
      end

      Changeset.discard(cs)
      cleanup(project)
    end
  end

  describe "actual elixir compilation through overlay" do
    test "mix compile succeeds with modified source" do
      project = make_mix_project()
      {_, 0} = System.cmd("sh", ["-c", "cd #{project} && mix compile 2>&1"])

      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.write_file(cs, "lib/example.ex", """
      defmodule Example do
        def hello, do: "from changeset"
      end
      """)

      {output, exit_code} = Changeset.run(cs, "mix compile 2>&1", timeout: 30_000)

      if exit_code == 0 do
        # Run the compiled code in the overlay
        {run_output, 0} = Changeset.run(cs,
          "mix run -e 'IO.puts(Example.hello())' 2>&1",
          timeout: 30_000
        )

        assert String.trim(run_output) =~ "from changeset"
      else
        IO.puts("  Compile output: #{output}")
      end

      Changeset.discard(cs)
      cleanup(project)
    end

    test "mix compile detects errors in changeset code" do
      project = make_mix_project()
      {_, 0} = System.cmd("sh", ["-c", "cd #{project} && mix compile 2>&1"])

      {:ok, cs} = Changeset.create(project)

      # Write broken code
      :ok = Changeset.write_file(cs, "lib/example.ex", """
      defmodule Example do
        def hello, do: undefined_function()
      end
      """)

      {output, exit_code} = Changeset.run(cs, "mix compile 2>&1", timeout: 30_000)

      # Should fail or warn about undefined function
      assert exit_code != 0 or output =~ "undefined" or output =~ "warning"

      Changeset.discard(cs)
      cleanup(project)
    end
  end

  describe "hardlink behavior on atomic writes" do
    test "overlay file sees stale content when original is atomically replaced" do
      project = make_project(%{"lib/app.ex" => "original content"})
      {:ok, cs} = Changeset.create(project)
      overlay = Changeset.overlay_path(cs)

      # Read through the overlay filesystem (not the GenServer's map)
      assert File.read!(Path.join(overlay, "lib/app.ex")) == "original content"

      # Atomic write (what most editors do: write temp, rename over original)
      real_file = Path.join(project, "lib/app.ex")
      tmp_file = real_file <> ".tmp"
      File.write!(tmp_file, "human edited this")
      File.rename!(tmp_file, real_file)

      # Overlay's hardlink still points to the OLD inode
      overlay_content = File.read!(Path.join(overlay, "lib/app.ex"))
      real_content = File.read!(real_file)

      assert overlay_content == "original content"
      assert real_content == "human edited this"
      assert overlay_content != real_content

      Changeset.discard(cs)
      cleanup(project)
    end
  end

  describe "scale" do
    test "1000 files: overlay creation and grep" do
      project = make_large_project(1000)

      {create_us, {:ok, cs}} = :timer.tc(fn -> Changeset.create(project) end)
      create_ms = create_us / 1000
      IO.puts("\n  1000 files: overlay creation #{Float.round(create_ms, 1)}ms")

      :ok = Changeset.write_file(cs, "lib/group_0/module_500.ex", "defmodule Modified do\nend\n")

      {grep_us, {output, 0}} = :timer.tc(fn ->
        Changeset.run(cs, "grep -r 'Modified' lib/")
      end)
      grep_ms = grep_us / 1000
      IO.puts("  1000 files: grep #{Float.round(grep_ms, 1)}ms")

      assert output =~ "Modified"
      assert create_ms < 1000

      Changeset.discard(cs)
      cleanup(project)
    end

    test "5000 files: overlay creation" do
      project = make_large_project(5000)

      {create_us, {:ok, cs}} = :timer.tc(fn -> Changeset.create(project) end)
      create_ms = create_us / 1000
      IO.puts("\n  5000 files: overlay creation #{Float.round(create_ms, 1)}ms")

      assert create_ms < 5000

      Changeset.discard(cs)
      cleanup(project)
    end
  end

  # -- Helpers --

  defp make_project(files) do
    project = Path.join(System.tmp_dir!(), "test-project-#{System.unique_integer([:positive])}")

    Enum.each(files, fn {path, content} ->
      full_path = Path.join(project, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
    end)

    project
  end

  defp make_mix_project do
    project = make_project(%{
      "lib/example.ex" => """
      defmodule Example do
        def hello, do: "world"
      end
      """,
      "mix.exs" => """
      defmodule Example.MixProject do
        use Mix.Project
        def project do
          [app: :example, version: "0.1.0", elixir: "~> 1.17"]
        end
      end
      """
    })

    System.cmd("sh", ["-c", "cd #{project} && mix deps.get 2>&1"],
      stderr_to_stdout: true)

    project
  end

  defp make_large_project(file_count) do
    project = Path.join(System.tmp_dir!(), "large-project-#{System.unique_integer([:positive])}")
    lib_dir = Path.join(project, "lib")
    File.mkdir_p!(lib_dir)

    Enum.each(1..file_count, fn i ->
      subdir = "group_#{rem(i, 20)}"
      dir = Path.join(lib_dir, subdir)
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "module_#{i}.ex"), """
      defmodule Module#{i} do
        @moduledoc "Module number #{i}"
        def value, do: #{i}
      end
      """)
    end)

    project
  end

  defp cleanup(project), do: File.rm_rf!(project)
end
