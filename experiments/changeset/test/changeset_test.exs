defmodule ChangesetTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Integration tests proving the core concept: in-memory edits are
  visible to Unix tools through the overlay directory.
  """

  setup do
    # Create a temporary "project" with some files
    project = Path.join(System.tmp_dir!(), "test-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(project, "lib/math"))
    File.mkdir_p!(Path.join(project, "lib/util"))
    File.mkdir_p!(Path.join(project, "test"))

    File.write!(Path.join(project, "lib/math/calc.ex"), """
    defmodule Math.Calc do
      def add(a, b), do: a + b
      def multiply(a, b), do: a * b
    end
    """)

    File.write!(Path.join(project, "lib/util/string_helper.ex"), """
    defmodule Util.StringHelper do
      def shout(s), do: String.upcase(s) <> "!"
    end
    """)

    File.write!(Path.join(project, "lib/app.ex"), """
    defmodule App do
      def run do
        Math.Calc.add(1, 2)
      end
    end
    """)

    File.write!(Path.join(project, "test/calc_test.exs"), """
    defmodule Math.CalcTest do
      use ExUnit.Case
      test "add" do
        assert Math.Calc.add(1, 2) == 3
      end
    end
    """)

    File.write!(Path.join(project, "README.md"), "# Test Project\n")

    on_exit(fn -> File.rm_rf!(project) end)

    %{project: project}
  end

  describe "create and discard" do
    test "creates an overlay with real dirs and hardlinked files", %{project: project} do
      {:ok, cs} = Changeset.create(project)
      overlay = Changeset.overlay_path(cs)

      # Overlay exists
      assert File.dir?(overlay)

      # Directories are real (not symlinks)
      assert File.dir?(Path.join(overlay, "lib"))
      assert {:error, _} = File.read_link(Path.join(overlay, "lib"))

      # Files are hardlinks (same inode as original)
      {:ok, overlay_stat} = File.stat(Path.join(overlay, "README.md"))
      {:ok, project_stat} = File.stat(Path.join(project, "README.md"))
      assert overlay_stat.inode == project_stat.inode

      # Content is accessible
      assert File.read!(Path.join(overlay, "lib/math/calc.ex")) =~ "def add"

      Changeset.discard(cs)
    end

    test "discard cleans up the overlay without touching the project", %{project: project} do
      {:ok, cs} = Changeset.create(project)
      overlay = Changeset.overlay_path(cs)

      Changeset.write_file(cs, "lib/new_file.ex", "new content")
      Changeset.discard(cs)

      # Overlay is gone
      refute File.exists?(overlay)

      # Project is untouched
      assert File.read!(Path.join(project, "lib/math/calc.ex")) =~ "def add"
      refute File.exists?(Path.join(project, "lib/new_file.ex"))
    end
  end

  describe "write_file" do
    test "modified file is visible in overlay, original unchanged", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      new_content = """
      defmodule Math.Calc do
        def add(a, b), do: a + b
        def multiply(a, b), do: a * b
        def subtract(a, b), do: a - b
      end
      """

      :ok = Changeset.write_file(cs, "lib/math/calc.ex", new_content)

      # Overlay has the new content
      overlay = Changeset.overlay_path(cs)
      assert File.read!(Path.join(overlay, "lib/math/calc.ex")) =~ "subtract"

      # Real project is unchanged
      refute File.read!(Path.join(project, "lib/math/calc.ex")) =~ "subtract"

      # Sibling file is still accessible via symlink
      assert File.read!(Path.join(overlay, "lib/util/string_helper.ex")) =~ "shout"

      Changeset.discard(cs)
    end

    test "new file appears in overlay", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.write_file(cs, "lib/math/geometry.ex", """
      defmodule Math.Geometry do
        def area(r), do: :math.pi() * r * r
      end
      """)

      overlay = Changeset.overlay_path(cs)
      assert File.read!(Path.join(overlay, "lib/math/geometry.ex")) =~ "Geometry"

      # Doesn't exist in real project
      refute File.exists?(Path.join(project, "lib/math/geometry.ex"))

      Changeset.discard(cs)
    end
  end

  describe "edit_file" do
    test "find-and-replace works", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.edit_file(cs, "lib/app.ex", "Math.Calc.add", "Math.Calc.subtract")

      {:ok, content} = Changeset.read_file(cs, "lib/app.ex")
      assert content =~ "Math.Calc.subtract"
      refute content =~ "Math.Calc.add"

      Changeset.discard(cs)
    end

    test "returns error when text not found", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      assert {:error, :text_not_found} =
               Changeset.edit_file(cs, "lib/app.ex", "nonexistent_text", "replacement")

      Changeset.discard(cs)
    end

    test "chained edits accumulate", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.edit_file(cs, "lib/math/calc.ex", "def add", "def sum")
      :ok = Changeset.edit_file(cs, "lib/math/calc.ex", "def multiply", "def product")

      {:ok, content} = Changeset.read_file(cs, "lib/math/calc.ex")
      assert content =~ "def sum"
      assert content =~ "def product"
      refute content =~ "def add"
      refute content =~ "def multiply"

      Changeset.discard(cs)
    end
  end

  describe "Unix tools see changes through the overlay" do
    test "grep finds content in modified files", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.edit_file(cs, "lib/math/calc.ex", "def add", "def sum")

      # grep sees the new function name
      {output, 0} = Changeset.run(cs, "grep -r 'def sum' lib/")
      assert output =~ "def sum"

      # grep does NOT find the old name
      {_output, exit_code} = Changeset.run(cs, "grep -r 'def add' lib/")
      assert exit_code != 0

      Changeset.discard(cs)
    end

    test "grep finds content in unmodified files", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      # Modify one file
      :ok = Changeset.write_file(cs, "lib/math/calc.ex", "modified")

      # Unmodified file is still searchable
      {output, 0} = Changeset.run(cs, "grep -r 'shout' lib/")
      assert output =~ "shout"

      Changeset.discard(cs)
    end

    test "cat reads modified content", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.write_file(cs, "lib/app.ex", "REPLACED CONTENT")

      {output, 0} = Changeset.run(cs, "cat lib/app.ex")
      assert output =~ "REPLACED CONTENT"

      Changeset.discard(cs)
    end

    test "find lists both modified and unmodified files", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.write_file(cs, "lib/math/geometry.ex", "new file")

      {output, 0} = Changeset.run(cs, "find lib -name '*.ex' | sort")
      assert output =~ "calc.ex"
      assert output =~ "string_helper.ex"
      assert output =~ "geometry.ex"
      assert output =~ "app.ex"

      Changeset.discard(cs)
    end

    test "wc counts lines in modified file", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.write_file(cs, "lib/app.ex", "line1\nline2\nline3\n")

      {output, 0} = Changeset.run(cs, "wc -l lib/app.ex")
      assert output =~ "3"

      Changeset.discard(cs)
    end
  end

  describe "merge" do
    test "merge writes changes to the real project", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.edit_file(cs, "lib/math/calc.ex", "def add", "def sum")
      :ok = Changeset.write_file(cs, "lib/math/geometry.ex", "defmodule Geometry do\nend\n")

      :ok = Changeset.merge(cs)

      # Real project has the changes
      assert File.read!(Path.join(project, "lib/math/calc.ex")) =~ "def sum"
      assert File.read!(Path.join(project, "lib/math/geometry.ex")) =~ "Geometry"
    end

    test "merge cleans up overlay", %{project: project} do
      {:ok, cs} = Changeset.create(project)
      overlay = Changeset.overlay_path(cs)

      :ok = Changeset.write_file(cs, "lib/app.ex", "modified")
      :ok = Changeset.merge(cs)

      refute File.exists?(overlay)
    end
  end

  describe "multiple changesets coexist" do
    test "two changesets see their own changes independently", %{project: project} do
      {:ok, cs_a} = Changeset.create(project)
      {:ok, cs_b} = Changeset.create(project)

      # Agent A renames add to sum
      :ok = Changeset.edit_file(cs_a, "lib/math/calc.ex", "def add", "def sum")

      # Agent B renames add to plus
      :ok = Changeset.edit_file(cs_b, "lib/math/calc.ex", "def add", "def plus")

      # Each sees only its own change
      {output_a, 0} = Changeset.run(cs_a, "grep 'def sum' lib/math/calc.ex")
      assert output_a =~ "def sum"

      {output_b, 0} = Changeset.run(cs_b, "grep 'def plus' lib/math/calc.ex")
      assert output_b =~ "def plus"

      # Neither sees the other's change
      {_, exit_a} = Changeset.run(cs_a, "grep 'def plus' lib/math/calc.ex")
      assert exit_a != 0

      {_, exit_b} = Changeset.run(cs_b, "grep 'def sum' lib/math/calc.ex")
      assert exit_b != 0

      # Real project is unchanged
      assert File.read!(Path.join(project, "lib/math/calc.ex")) =~ "def add"

      Changeset.discard(cs_a)
      Changeset.discard(cs_b)
    end
  end

  describe "summary and modified_files" do
    test "tracks modifications", %{project: project} do
      {:ok, cs} = Changeset.create(project)

      :ok = Changeset.edit_file(cs, "lib/math/calc.ex", "def add", "def sum")
      :ok = Changeset.write_file(cs, "lib/new.ex", "new file content")

      assert Changeset.modified_files(cs).modified == ["lib/math/calc.ex", "lib/new.ex"]

      summary = Changeset.summary(cs)
      assert length(summary) == 2

      calc = Enum.find(summary, &(&1.path == "lib/math/calc.ex"))
      assert calc.kind == :modified

      new = Enum.find(summary, &(&1.path == "lib/new.ex"))
      assert new.kind == :new

      Changeset.discard(cs)
    end
  end
end
