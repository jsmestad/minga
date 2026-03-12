defmodule Minga.Agent.InstructionsTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Instructions

  @moduletag :tmp_dir

  describe "discover/2" do
    test "finds project root AGENTS.md", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Project rules here")

      results = Instructions.discover(dir)
      assert length(results) == 1
      assert hd(results).label == "Project Instructions"
      assert hd(results).content == "Project rules here"
    end

    test "finds .minga/AGENTS.md", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".minga"))
      File.write!(Path.join([dir, ".minga", "AGENTS.md"]), "Config rules")

      results = Instructions.discover(dir)
      assert length(results) == 1
      assert hd(results).label == "Project Config Instructions"
    end

    test "finds both project root and .minga AGENTS.md", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Root rules")
      File.mkdir_p!(Path.join(dir, ".minga"))
      File.write!(Path.join([dir, ".minga", "AGENTS.md"]), "Config rules")

      results = Instructions.discover(dir)
      assert length(results) == 2
      labels = Enum.map(results, & &1.label)
      assert "Project Instructions" in labels
      assert "Project Config Instructions" in labels
    end

    test "returns empty list when no files exist", %{tmp_dir: dir} do
      assert Instructions.discover(dir) == []
    end

    test "finds directory-scoped AGENTS.md", %{tmp_dir: dir} do
      # Create a subdirectory with its own AGENTS.md
      sub = Path.join([dir, "lib", "agent"])
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "AGENTS.md"), "Agent-specific rules")

      current_file = Path.join(sub, "some_file.ex")
      results = Instructions.discover(dir, current_file)

      dir_results = Enum.filter(results, &String.starts_with?(&1.label, "Directory"))
      assert length(dir_results) == 1
      assert hd(dir_results).content == "Agent-specific rules"
    end

    test "directory-scoped discovery walks up to root", %{tmp_dir: dir} do
      # Create AGENTS.md at multiple levels
      lib = Path.join(dir, "lib")
      agent = Path.join(lib, "agent")
      File.mkdir_p!(agent)
      File.write!(Path.join(lib, "AGENTS.md"), "Lib rules")
      File.write!(Path.join(agent, "AGENTS.md"), "Agent rules")

      current_file = Path.join(agent, "foo.ex")
      results = Instructions.discover(dir, current_file)

      dir_results = Enum.filter(results, &String.starts_with?(&1.label, "Directory"))
      assert length(dir_results) == 2
    end

    test "skips empty files", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "")
      assert Instructions.discover(dir) == []
    end
  end

  describe "assemble/2" do
    test "returns nil when no files found", %{tmp_dir: dir} do
      assert Instructions.assemble(dir) == nil
    end

    test "returns assembled content with section headers", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Use tabs not spaces")

      result = Instructions.assemble(dir)
      assert result =~ "## Project Instructions"
      assert result =~ "Use tabs not spaces"
    end

    test "multiple files are separated by headers", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Root rules")
      File.mkdir_p!(Path.join(dir, ".minga"))
      File.write!(Path.join([dir, ".minga", "AGENTS.md"]), "Config rules")

      result = Instructions.assemble(dir)
      assert result =~ "## Project Instructions"
      assert result =~ "## Project Config Instructions"
      assert result =~ "Root rules"
      assert result =~ "Config rules"
    end
  end

  describe "summary/2" do
    test "shows no files message when none found", %{tmp_dir: dir} do
      result = Instructions.summary(dir)
      assert result =~ "No instruction files found"
    end

    test "lists found files with sizes", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Some content here")

      result = Instructions.summary(dir)
      assert result =~ "Loaded 1 instruction file(s)"
      assert result =~ "✓ Project Instructions"
      assert result =~ "chars"
    end
  end
end
